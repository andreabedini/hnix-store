{-|
Description : Build related types
Maintainer  : srk <srk@48.io>
|-}
module System.Nix.Build
  ( BuildMode(..)
  , BuildStatus(..)
  , BuildResult(..)
  , buildSuccess
  ) where

import Data.Time (UTCTime)
import Data.Text (Text)
import GHC.Generics (Generic)

-- keep the order of these Enums to match enums from reference implementations
-- src/libstore/store-api.hh
data BuildMode
  = BuildMode_Normal
  | BuildMode_Repair
  | BuildMode_Check
  deriving (Eq, Generic, Ord, Enum, Show)

data BuildStatus =
    BuildStatus_Built
  | BuildStatus_Substituted
  | BuildStatus_AlreadyValid
  | BuildStatus_PermanentFailure
  | BuildStatus_InputRejected
  | BuildStatus_OutputRejected
  | BuildStatus_TransientFailure -- possibly transient
  | BuildStatus_CachedFailure    -- no longer used
  | BuildStatus_TimedOut
  | BuildStatus_MiscFailure
  | BuildStatus_DependencyFailed
  | BuildStatus_LogLimitExceeded
  | BuildStatus_NotDeterministic
  | BuildStatus_ResolvesToAlreadyValid
  | BuildStatus_NoSubstituters
  deriving (Eq, Generic, Ord, Enum, Show)

-- | Result of the build
data BuildResult = BuildResult
  { -- | build status, MiscFailure should be default
    status             :: !BuildStatus
  , -- | possible build error message
    errorMessage       :: !(Maybe Text)
  , -- | How many times this build was performed
    timesBuilt         :: !Int
  , -- | If timesBuilt > 1, whether some builds did not produce the same result
    isNonDeterministic :: !Bool
  ,  -- Start time of this build
    startTime          :: !UTCTime
  ,  -- Stop time of this build
    stopTime           :: !UTCTime
  }
  deriving (Eq, Generic, Ord, Show)

buildSuccess :: BuildResult -> Bool
buildSuccess BuildResult {..} =
  status `elem`
    [ BuildStatus_Built
    , BuildStatus_Substituted
    , BuildStatus_AlreadyValid
    ]
