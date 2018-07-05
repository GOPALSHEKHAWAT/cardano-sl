{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DuplicateRecordFields      #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TupleSections              #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE ViewPatterns               #-}
{-# OPTIONS_GHC -Wall #-}
module Cardano.Faucet.Init (initEnv) where

import           Control.Concurrent (forkIO, threadDelay)
import           Control.Concurrent.STM (atomically)
import qualified Control.Concurrent.STM.TBQueue as TBQ
import           Control.Concurrent.STM.TMVar (putTMVar)
import           Control.Exception (catch, throw)
import           Control.Lens hiding ((.=))
import           Control.Monad.Except
import           Data.Aeson (FromJSON, eitherDecode)
import           Data.Aeson.Text (encodeToLazyText)
import           Data.Bifunctor (first)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import           Data.Default (def)
import           Data.Int (Int64)
import           Data.List.NonEmpty as NonEmpty
import           Data.Monoid ((<>))
import qualified Data.Text as Text
import           Data.Text.Lazy (toStrict)
import qualified Data.Text.Lazy.IO as Text
import           Data.Text.Lens (packed)
import           Network.Connection (TLSSettings (..))
import           Network.HTTP.Client (Manager, newManager)
import           Network.HTTP.Client.TLS (mkManagerSettings)
import           Network.TLS (ClientParams (..), credentialLoadX509FromMemory,
                     defaultParamsClient, onCertificateRequest,
                     onServerCertificate, supportedCiphers)
import           Network.TLS.Extra.Cipher (ciphersuite_strong)
import           Servant.Client.Core (BaseUrl (..), Scheme (..))
import           System.Directory (createDirectoryIfMissing)
import           System.FilePath (takeDirectory)
import           System.IO.Error (isDoesNotExistError)
import           System.Metrics (Store, createCounter, createGauge)
import qualified System.Metrics.Gauge as Gauge
import           System.Wlog (CanLog, HasLoggerName, LoggerNameBox (..),
                     liftLogIO, logError, logInfo, withSublogger)

import           Cardano.Wallet.API.V1.Types (Account (..),
                     AssuranceLevel (NormalAssurance), NewWallet (..),
                     NodeInfo (..), Payment (..), PaymentDistribution (..),
                     PaymentSource (..), SyncPercentage, V1 (..), Wallet (..),
                     WalletAddress (..), WalletOperation (CreateWallet),
                     mkSyncPercentage, txAmount, unV1)
import           Cardano.Wallet.Client (ClientError (..), WalletClient (..),
                     WalletResponse (..), liftClient)
import           Cardano.Wallet.Client.Http (mkHttpClient)
import           Pos.Core (Coin (..))
import           Pos.Util.Mnemonic (Mnemonic, entropyToMnemonic, genEntropy)

import           Cardano.Faucet.Types


--------------------------------------------------------------------------------
-- | Parses a 'SourceWalletConfig' from a file containing JSON
readSourceWalletConfig :: FilePath -> IO (Either String SourceWalletConfig)
readSourceWalletConfig = readJSON

readJSON :: FromJSON a => FilePath -> IO (Either String a)
readJSON = fmap eitherDecode . BSL.readFile

data CreatedWalletReadError =
    JSONDecodeError String
  | FileNotPresentError
  | FileReadError IOError

readGeneratedWallet :: FilePath -> IO (Either CreatedWalletReadError CreatedWallet)
readGeneratedWallet fp = catch (first JSONDecodeError <$> readJSON fp) $ \e ->
    if isDoesNotExistError e
      then return $ Left FileNotPresentError
      else return $ Left $ FileReadError e
--------------------------------------------------------------------------------
generateBackupPhrase :: IO (Mnemonic 12)
generateBackupPhrase = entropyToMnemonic <$> genEntropy

--------------------------------------------------------------------------------
completelySynced :: SyncPercentage
completelySynced = mkSyncPercentage 100

-- | Looks up the 'SyncPercentage' using 'getNodeInfo' from the 'WalletClient'
getSyncState
    :: (HasLoggerName m, MonadIO m)
    => WalletClient m
    -> m (Either ClientError SyncPercentage)
getSyncState client = do
    r <- getNodeInfo client
    return (nfoSyncProgress . wrData <$> r)

--------------------------------------------------------------------------------
-- | Creates a new wallet
--
-- Before creating the wallet the 'SyncState' of the node the 'WalletClient' is
-- pointing at checked. If it's less than 100% we wait 5 seconds and try again
createWallet
    :: (HasLoggerName m, CanLog m, MonadIO m)
    => WalletClient m
    -> m (Either InitFaucetError CreatedWallet)
createWallet client = do
    sync <- getSyncState client
    case sync of
        Left err -> do
            logError $ "Error getting sync state: " <> (Text.pack $ show err)
            return . Left $ CouldntReadBalance err
        Right ss | ss >= completelySynced -> do
                       logInfo "Node fully synced, creating wallet"
                       mkWallet
                 | otherwise -> do
                       logInfo $ "Node not fully synced: " <> (Text.pack $ show ss)
                       liftIO $ threadDelay 5000000
                       createWallet client
    where
        listToEitherT err errMsg successMsg as = case as of
            [a] -> logInfo successMsg >> return a
            _   -> logError errMsg >> throwError err
        mkWallet = do
          phrase <- liftIO generateBackupPhrase
          let w = NewWallet (V1 phrase) Nothing NormalAssurance "Faucet-Wallet" CreateWallet
          runExceptT $ do
              wId <- walId <$> (runClient WalletCreationError $ postWallet client w)
              let wIdLog = Text.pack $ show wId
              logInfo $ "Created wallet with ID: " <> wIdLog
              accounts <- runClient WalletCreationError $
                            getAccountIndexPaged
                              client
                              wId
                              Nothing
                              Nothing
              acc <- listToEitherT
                          (NoWalletAccounts wId)
                          ("Didn't find an account for wallet with ID: " <> wIdLog)
                          ("Found a single account for wallet with ID: " <> wIdLog)
                          accounts
              let aIdx = accIndex acc
                  aIdxLog = Text.pack $ show aIdx
              address <- listToEitherT
                          (BadAddress wId aIdx)
                          ("Didn't find an address for wallet with ID: "
                                        <> wIdLog
                                        <> " account index: " <> aIdxLog)
                          ("Found a single address for wallet with ID: "
                                        <> wIdLog
                                        <> " account index: " <> aIdxLog)
                          (accAddresses acc)
              return (CreatedWallet wId phrase aIdx (unV1 $ addrId address))
        runClient err m = ExceptT $ (fmap (first err)) $ fmap (fmap wrData) m

--------------------------------------------------------------------------------
-- | Writes a JSON encoded 'CreatedWallet' to the given 'FilePath'
--
-- Creates the parent directory if required
writeCreatedWalletInfo :: FilePath -> CreatedWallet -> IO ()
writeCreatedWalletInfo fp cw = do
    let theDir = takeDirectory fp
    createDirectoryIfMissing True theDir
    Text.writeFile fp $ encodeToLazyText cw

--------------------------------------------------------------------------------
-- | Reads the balance of an existing wallet
--
-- Fails with 'CouldntReadBalance'
readWalletBalance
    :: (HasLoggerName m, MonadIO m)
    => WalletClient m
    -> PaymentSource
    -> m (Either InitFaucetError Int64)
readWalletBalance client (psWalletId -> wId) = do
    r <- getWallet client wId
    return $ first CouldntReadBalance
           $ fmap (fromIntegral . getCoin . unV1 . walBalance . wrData) $ r

-- | Creates the 'IntializedWallet' for a given config
--
-- * In the case of 'Provided' it will use the details of an (existing) wallet by
-- reading from a JSON serialised 'SourceWalletConfig' (and looking up its balance)
-- * If the 'FaucetConfig''s `fcSourceWallet` is 'Generate' a new wallet is
-- created with 'createWallet' and the details are written to the provided
-- 'FilePath'
makeInitializedWallet
    :: (HasLoggerName m, CanLog m, MonadIO m)
    => FaucetConfig
    -> WalletClient m
    -> m (Either InitFaucetError InitializedWallet)
makeInitializedWallet fc client = withSublogger "makeInitializedWallet" $ do
    case (fc ^. fcSourceWallet) of
        Provided fp -> do
            logInfo ("Reading existing wallet details from " <> Text.pack fp)
            srcCfg <- liftIO $ readSourceWalletConfig fp
            case srcCfg of
                Left err -> do
                    logError ( "Error decoding source wallet in read-from: "
                            <> Text.pack err)
                    return $ Left $ SourceWalletParseError err
                Right wc -> do
                    logInfo "Successfully read wallet config"
                    let ps = cfgToPaymentSource wc
                    fmap (InitializedWallet wc) <$> do
                        logInfo "Reading initial wallet balance"
                        readWalletBalance client ps
        Generate fp -> do
            logInfo ("Generating wallet details to " <> Text.pack fp <> " (or using existing)")
            eGenWal <- liftIO $ readGeneratedWallet fp
            resp <- case eGenWal of
                Left (JSONDecodeError err) -> do
                    logError ( "Error decoding existing generated wallet: "
                            <> Text.pack err)
                    left $ CreatedWalletReadError err
                Left (FileReadError e) -> do
                    let err = show e
                    logError ( "Error reading file for existing generated wallet: "
                            <> Text.pack err)
                    left $ CreatedWalletReadError err
                Left FileNotPresentError -> do
                    logInfo "File specified in generate-to doesn't exist. Creating wallet"
                    createdWallet <- createWallet client
                    forM_ createdWallet $ \cw -> liftIO $ writeCreatedWalletInfo fp cw
                    return createdWallet
                Right cw -> do
                    logInfo "Wallet read from file specified in generate-to."
                    return $ Right cw
            forM resp $ \(CreatedWallet wallet _phrase accIdx _addr) -> do
                    let swc = SourceWalletConfig wallet accIdx Nothing
                        iw = InitializedWallet swc 0
                    return iw
    where
        left = return . Left

--------------------------------------------------------------------------------
processWithdrawls :: FaucetEnv -> LoggerNameBox IO ()
processWithdrawls fEnv = withSublogger "processWithdrawls" $ forever $ do
    let wc = fEnv ^. feWalletClient
        pmtQ = fEnv ^. feWithdrawlQ
    logInfo "Waiting for next payment"
    (ProcessorPayload pmt tVarResult)<- liftIOA $ TBQ.readTBQueue pmtQ
    logInfo "Processing payment"
    resp <- liftIO $ postTransaction wc pmt
    case resp of
        Left err -> do
            let txtErr = err ^. to show . packed
            logError ("Error sending to " <> (showPmt pmt)
                                          <> " error: "
                                          <> txtErr)
            liftIOA $ putTMVar tVarResult (WithdrawlError txtErr)
        Right withDrawResp -> do
            let txn = wrData withDrawResp
                amount = unV1 $ txAmount txn
            logInfo ((withDrawResp ^. to (show . wrStatus) . packed)
                    <> " withdrew: "
                    <> (amount ^. to show . packed))
            liftIOA $ putTMVar tVarResult (WithdrawlSuccess txn)
    where
      liftIOA = liftIO . atomically
      showPmt = toStrict . encodeToLazyText . pdAddress . NonEmpty.head . pmtDestinations

-- | Creates a 'FaucetEnv' from a given 'FaucetConfig'
--
-- Also sets the 'Gauge.Gauge' for the 'feWalletBalance'
initEnv :: FaucetConfig -> Store -> LoggerNameBox IO FaucetEnv
initEnv fc store = do
    withSublogger "initEnv" $ logInfo "Initializing environment"
    env <- createEnv
    withSublogger "initEnv" $ logInfo "Created environment"
    tID <- liftLogIO forkIO $ processWithdrawls env
    withSublogger "initEnv" $ logInfo ("Forked thread for processing withdrawls:" <> show tID ^. packed)
    return env
  where
    createEnv = withSublogger "init" $ do
      walletBalanceGauge <- liftIO $ createGauge "wallet-balance" store
      feConstruct <- liftIO $ FaucetEnv
        <$> createCounter "total-withdrawn" store
        <*> createCounter "num-withdrawals" store
        <*> pure walletBalanceGauge
      logInfo "Creating Manager"
      manager <- liftIO $ createManager fc
      let url = BaseUrl Https (fc ^. fcWalletApiHost) (fc ^. fcWalletApiPort) ""
          client = mkHttpClient url manager
      logInfo "Initializing wallet"
      initialWallet <- makeInitializedWallet fc (liftClient client)
      pmtQ <- liftIO $ TBQ.newTBQueueIO 10
      case initialWallet of
          Left err -> do
              logError ( "Error initializing wallet. Exiting: "
                      <> (show err ^. packed))
              throw err
          Right iw -> do
              logInfo ( "Initialised wallet: "
                    <> (iw ^. walletConfig . srcWalletId . to show . packed))
              liftIO $ Gauge.set walletBalanceGauge (iw ^. walletBalance)
              return $ feConstruct
                          store
                          (iw ^. walletConfig)
                          fc
                          client
                          pmtQ


-- | Makes a http client 'Manager' for communicating with the wallet node
createManager :: FaucetConfig -> IO Manager
createManager fc = do
    pubCert <- BS.readFile (fc ^. fcPubCertFile)
    privKey <- BS.readFile (fc ^. fcPrivKeyFile)
    case credentialLoadX509FromMemory pubCert privKey of
        Left problem -> error $ "Unable to load credentials: " <> (problem ^. packed)
        Right credential ->
            let hooks = def {
                            onCertificateRequest = \_ -> return $ Just credential,
                            -- Only connects to localhost so this isn't required
                            onServerCertificate  = \_ _ _ _ -> return []
                        }
                clientParams = (defaultParamsClient "localhost" "") {
                                   clientHooks = hooks,
                                   clientSupported = def {
                                       supportedCiphers = ciphersuite_strong
                                   }
                               }
                tlsSettings = TLSSettings clientParams
            in
            newManager $ mkManagerSettings tlsSettings Nothing
