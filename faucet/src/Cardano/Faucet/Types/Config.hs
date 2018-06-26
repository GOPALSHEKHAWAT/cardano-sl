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
{-# OPTIONS_GHC -Wall #-}
module Cardano.Faucet.Types.Config (
   FaucetConfig(..)
 , HasFaucetConfig(..)
 , FaucetEnv(..)
 , HasFaucetEnv(..)
 , SourceWalletConfig(..)
 , srcSpendingPassword
 , cfgToPaymentSource
 , SourceWallet(..)
 , InitializedWallet(..), walletBalance, walletConfig
 , CreatedWallet(..)
 , InitFaucetError(..)
  ) where

import           Control.Applicative ((<|>))
import           Control.Exception (Exception)
import           Control.Lens hiding ((.=))
import           Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.:?), (.=))
import           Data.Int (Int64)
import           Data.Text (Text)
import           Data.Typeable (Typeable)
import           GHC.Generics (Generic)
import           System.Metrics (Store)
import           System.Metrics.Counter (Counter)
import           System.Metrics.Gauge (Gauge)
import           System.Remote.Monitoring.Statsd (StatsdOptions (..))

import           Cardano.Wallet.API.V1.Types (AccountIndex, PaymentSource (..), WalletId (..))
import           Cardano.Wallet.Client (ClientError (..), WalletClient (..))
import           Pos.Core (Address (..))
import           Pos.Util.Mnemonic (Mnemonic)


--------------------------------------------------------------------------------
-- | Newtype for 'StatsdOptions' for the 'FromJSON' instance
newtype FaucetStatsdOpts = FaucetStatsdOpts StatsdOptions deriving (Generic)

makeWrapped ''FaucetStatsdOpts

instance FromJSON FaucetStatsdOpts where
    parseJSON = fmap FaucetStatsdOpts . (withObject "StatsdOptions" $ \v ->
        StatsdOptions
          <$> v .: "host"
          <*> v .: "port"
          <*> v .: "flush-interval"
          <*> pure False
          <*> pure "faucet"
          <*> pure "")

--------------------------------------------------------------------------------
-- | Configuration for making the faucet use an existing wallet
--
-- /This wallet may have just been created by the faucet starting up/
data SourceWalletConfig = SourceWalletConfig {
    -- | An ID for an existing wallet
    _srcWalletId         :: !WalletId
    -- | The index of an existing account in the wallet
  , _srcAccountIndex     :: !AccountIndex
    -- | Optional spending password for the account ('Nothing' if no password)
  , _srcSpendingPassword :: !(Maybe Text)
  } deriving (Generic, Show)

-- | 'Lens' to the spending password
srcSpendingPassword :: Lens' SourceWalletConfig (Maybe Text)
srcSpendingPassword f = \(SourceWalletConfig w a p) ->
    SourceWalletConfig w a <$> f p

instance FromJSON SourceWalletConfig where
    parseJSON = withObject "SourceWalletConfig" $ \v -> SourceWalletConfig
      <$> v .: "wallet-id"
      <*> v .: "account-index"
      <*> v .:? "spending-password"

-- | Turns a 'SourceWalletConfig' into a 'PaymentSource' needed to construct a 'Payment'
--
-- See 'Cardano.WalletClient.withdraw'
cfgToPaymentSource :: SourceWalletConfig -> PaymentSource
cfgToPaymentSource (SourceWalletConfig wId aIdx _) = PaymentSource wId aIdx

--------------------------------------------------------------------------------
-- | Config for the centre point of the payment amount distribution
--
-- The amount of ADA to send from the faucet is calculated using this and
-- 'PaymentVariation' to compute
--
-- @
--   'PaymentCenter' + randomFloat(-1, 1) * 'PaymentVariation'
-- @
newtype PaymentCenter = PaymentCenter Int deriving (Generic, Show, Eq, Ord)

makeWrapped ''PaymentCenter

instance FromJSON PaymentCenter

--------------------------------------------------------------------------------
-- | See 'PaymentCenter'
newtype PaymentVariation = PaymentVariation Float deriving (Generic, Show, Eq, Ord)

makeWrapped ''PaymentVariation

instance FromJSON PaymentVariation

--------------------------------------------------------------------------------
-- | Config for the wallet used by the faucet as a source of ADA
data SourceWallet
    -- | Tells the faucet to generate its own wallet at start up
    --
    -- After 'CreatedWallet' will be written to 'FilePath'
    = Generate !FilePath
    -- | Tells the faucet to read a 'SourceWalletConfig' from the 'FilePath'
    | Provided !FilePath

instance FromJSON SourceWallet where
    parseJSON = withObject "SourceWallet" $ \v ->
        (Generate <$> v .: "generate-to") <|> (Provided <$> v .: "read-from")

--------------------------------------------------------------------------------
-- | Once a wallet is created or read 'FaucetEnv' gets one of these
data InitializedWallet = InitializedWallet {
    -- | The details of the wallet
    _walletConfig  :: !SourceWalletConfig
    -- | The wallet's balance (0 if just created otherwise queried)
  , _walletBalance :: !Int64
  } deriving (Show, Generic)

makeLenses ''InitializedWallet

--------------------------------------------------------------------------------
-- | Static config provided to the faucet
data FaucetConfig = FaucetConfig {
    -- | Host the wallet API is running on
    _fcWalletApiHost    :: !String
    -- | Port the wallet API is running on
  , _fcWalletApiPort    :: !Int
    -- | Port to serve the faucet on
  , _fcPort             :: !Int
    -- | Midpoint for withdrawls (defaults to 1000)
  , _fcPaymentAmount    :: !PaymentCenter
    -- | Variation for withdrawls (defaults to 500)
  , _fcPaymentVariation :: !PaymentVariation
    -- | Statsd server details
  , _fcStatsdOpts       :: !FaucetStatsdOpts
    -- | Config for wallet to use for funds
  , _fcSourceWallet     :: !SourceWallet
    -- | Logging config file
  , _fcLoggerConfigFile :: !FilePath
    -- | TLS public certificate
  , _fcPubCertFile      :: !FilePath
    -- | TLS private key
  , _fcPrivKeyFile      :: !FilePath
  }

makeClassy ''FaucetConfig

instance FromJSON FaucetConfig where
    parseJSON = withObject "FaucetConfig" $ \v ->
        FaucetConfig
          <$> v .: "wallet-host"
          <*> v .: "wallet-port"
          <*> v .: "port"
          <*> v .: "payment-amount"
          <*> v .: "payment-variation"
          <*> v .: "statsd"
          <*> v .: "source-wallet"
          <*> v .: "logging-config"
          <*> v .: "public-certificate"
          <*> v .: "private-key"

--------------------------------------------------------------------------------
-- | Details of a wallet created by the faucet at run time if 'Generate' is used
data CreatedWallet = CreatedWallet {
    -- | ID of the created wallet
    _createdWalletId :: WalletId
    -- | 12 word recovery mnemonic
  , _createdPhrase   :: Mnemonic 12
    -- | Index of the account present in the created wallet
  , _createdAcctIdx  :: AccountIndex
    -- | Sending address within the account in the created wallet
  , _createdAddress  :: Address
  } deriving (Show, Generic)

instance ToJSON CreatedWallet where
    toJSON (CreatedWallet wId phrase acctIdx addr) =
        object [ "wallet-id" .= wId
               , "recovery-words" .= phrase
               , "account-index" .= acctIdx
               , "address" .= addr
               ]

--------------------------------------------------------------------------------
-- | Sum type for possible errors encountered at faucet startup time
data InitFaucetError =
    -- | Bad parse on the file suplying existing wallet details
    SourceWalletParseError String
    -- | Error reading sync state from wallet API
  | CouldntReadSyncState ClientError
    -- | Error creating a new wallet
  | WalletCreationError ClientError
    -- | Error reading the balance of an existing wallet
  | CouldntReadBalance ClientError
    -- | Error thrown if created wallet doesn't have an account (shouldn't happen)
  | NoWalletAccounts WalletId
    -- | Error thrown if exactly one address isn't found (shouln't happen)
  | BadAddress WalletId AccountIndex
  deriving (Typeable, Show)

instance Exception InitFaucetError

--------------------------------------------------------------------------------
-- | Run time environment for faucet's reader Monad
data FaucetEnv = FaucetEnv {
    -- | Counter for total amount withdawn from a wallet while faucet is running
    _feWithdrawn     :: !Counter
    -- | Counter for number of withdrawls made
  , _feNumWithdrawn  :: !Counter
    -- | Gauge for wallet balance
  , _feWalletBalance :: !Gauge
    -- | Metrics store
  , _feStore         :: !Store
    -- | Config for source of funds
  , _feSourceWallet  :: !SourceWalletConfig
    -- | Original static config object
  , _feFaucetConfig  :: !FaucetConfig
    -- | Client for communicating with wallet API
  , _feWalletClient  :: !(WalletClient IO)
  }

makeClassy ''FaucetEnv

-- |
-- === Metrics functions