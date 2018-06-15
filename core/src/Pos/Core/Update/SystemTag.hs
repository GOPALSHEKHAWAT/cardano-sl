{-# LANGUAGE DeriveLift #-}

module Pos.Core.Update.SystemTag
       ( SystemTag (..)
       , checkSystemTag
       , systemTagMaxLength

       , osHelper
       , archHelper
       ) where

import           Universum

import           Control.Monad.Except
                       (MonadError (throwError))
import           Data.Char
                       (isAscii)
import qualified Data.Text as T
import           Distribution.System
                       (Arch (..), OS (..))
import           Distribution.Text
                       (display)
import           Instances.TH.Lift ()
import           Language.Haskell.TH.Syntax
                       (Lift)

-- | Tag of system for which update data is purposed, e.g. win64, mac32
newtype SystemTag = SystemTag { getSystemTag :: Text }
  deriving (Eq, Ord, Show, Generic, Buildable, Hashable, Lift, Typeable)

instance NFData SystemTag

systemTagMaxLength :: Integral i => i
systemTagMaxLength = 10

checkSystemTag :: MonadError Text m => SystemTag -> m ()
checkSystemTag (SystemTag tag)
    | T.length tag > systemTagMaxLength
          = throwError "SystemTag: too long string passed"
    | T.any (not . isAscii) tag
          = throwError "SystemTag: not ascii string passed"
    | otherwise
          = pure ()

-- | Helper to turn an @OS@ into a @String@ compatible with the @systemTag@ previously
-- used in 'configuration.yaml'.
osHelper :: OS -> String
osHelper sys = case sys of
    Windows -> "win"
    OSX     -> "macos"
    Linux   -> "linux"
    _       -> display sys

-- | Helper to turn an @Arch@ into a @String@ compatible with the @systemTag@ previously
-- used in 'configuration.yaml'.
archHelper :: Arch -> String
archHelper archt = case archt of
    I386   -> "32"
    X86_64 -> "64"
    _      -> display archt
