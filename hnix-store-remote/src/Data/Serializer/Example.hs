{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Data.Serializer.Example
  (
  -- * Simple protocol
    OpCode(..)
  , Cmd(..)
  -- * Cmd Serializer
  , cmdS
  -- * Runners
  , runG
  , runP
  -- * Custom errors
  , MyGetError(..)
  , MyPutError(..)
  -- ** Erroring variants of cmdS
  -- *** putS with throwError and MyPutError
  , cmdSPutError
  -- *** getS with throwError and MyGetError
  , cmdSGetError
  -- *** getS with fail
  , cmdSGetFail
  -- *** putS with fail
  , cmdSPutFail
  -- * Elaborate
  , cmdSRest
  , runGRest
  , runPRest
  ) where

import Control.Monad.Except (MonadError, throwError)
import Control.Monad.Reader (MonadReader, ask)
import Control.Monad.State (MonadState)
import Control.Monad.Trans (MonadTrans, lift)
import Control.Monad.Trans.Reader (ReaderT, runReaderT)
import Control.Monad.Trans.Except (ExceptT, runExceptT)
import Control.Monad.Trans.State (StateT, runStateT)
import Data.Bifunctor (first, second)
import Data.ByteString (ByteString)
import Data.Int (Int8)
import Data.GADT.Show (GShow(..), defaultGshowsPrec)
import Data.Kind (Type)
import Data.Type.Equality
import Data.Serialize.Get (getInt8)
import Data.Serialize.Put (putInt8)
import Data.Serializer
import Data.Some (Some(..))
import GHC.Generics
import System.Nix.Store.Remote.Serialize.Prim (getBool, putBool, getEnum, putEnum)

import Test.QuickCheck (Arbitrary(..), oneof)

-- * Simple protocol

-- | OpCode used to differentiate between operations
data OpCode = OpCode_Int | OpCode_Bool
  deriving (Bounded, Eq, Enum, Generic, Ord, Show)

-- | Protocol operations
data Cmd :: Type -> Type where
  Cmd_Int :: Int8 -> Cmd Int8
  Cmd_Bool :: Bool -> Cmd Bool

deriving instance Eq (Cmd a)
deriving instance Show (Cmd a)

instance GShow Cmd where
  gshowsPrec = defaultGshowsPrec

instance TestEquality Cmd where
    testEquality (Cmd_Int _) (Cmd_Int _) = Just Refl
    testEquality (Cmd_Bool _) (Cmd_Bool _) = Just Refl
    testEquality _ _ = Nothing

-- constructors only
-- import Data.GADT.Compare
-- instance GEq Cmd where
--   geq = testEquality

instance {-# OVERLAPPING #-} Eq (Some Cmd) where
  Some (Cmd_Int a) == Some (Cmd_Int b) = a == b
  Some (Cmd_Bool a) == Some (Cmd_Bool b) = a == b
  _ == _ = False

instance Arbitrary (Some Cmd) where
  arbitrary = oneof
    [ Some . Cmd_Int <$> arbitrary
    , Some . Cmd_Bool <$> arbitrary
    ]

-- | @OpCode@ @Serializer@
opcode :: MonadTrans t => Serializer t OpCode
opcode = Serializer
  { getS = lift getEnum
  , putS = lift . putEnum
  }

-- * Cmd Serializer

-- | @Cmd@ @Serializer@
cmdS
  :: forall t . ( MonadTrans t
     , Monad (t Get)
     , Monad (t PutM)
     )
  => Serializer t (Some Cmd)
cmdS = Serializer
  { getS = getS opcode >>= \case
      OpCode_Int -> Some . Cmd_Int <$> lift getInt8
      OpCode_Bool -> Some . Cmd_Bool <$> lift getBool
  , putS = \case
      Some (Cmd_Int i) -> putS opcode OpCode_Int >> lift (putInt8 i)
      Some (Cmd_Bool b) -> putS opcode OpCode_Bool >> lift (putBool b)
  }

-- * Runners

-- | @runGetS@ specialized to @ExceptT e@
runG
  :: Serializer (ExceptT e) a
  -> ByteString
  -> Either (GetSerializerError e) a
runG s =
  transformGetError
  . runGetS s runExceptT

-- | @runPutS@ specialized to @ExceptT e@
runP
  :: Serializer (ExceptT e) a
  -> a
  -> Either e ByteString
runP s =
   (\(e, r) -> either Left (pure $ Right r) e)
  . runPutS s runExceptT

-- * Custom errors

data MyGetError
  = MyGetError_Example
  deriving (Eq, Show)

data MyPutError
  = MyPutError_NoLongerSupported -- no longer supported protocol version
  deriving (Eq, Show)

-- ** Erroring variants of cmdS

-- *** putS with throwError and MyPutError

cmdSPutError :: Serializer (ExceptT MyPutError) (Some Cmd)
cmdSPutError = Serializer
  { getS = getS cmdS
  , putS = \case
      Some (Cmd_Int i) -> putS opcode OpCode_Int >> lift (putInt8 i)
      Some (Cmd_Bool _b) -> throwError MyPutError_NoLongerSupported
  }

-- *** getS with throwError and MyGetError

cmdSGetError :: Serializer (ExceptT MyGetError) (Some Cmd)
cmdSGetError = Serializer
  { getS = getS opcode >>= \case
      OpCode_Int -> Some . Cmd_Int <$> lift getInt8
      OpCode_Bool -> throwError MyGetError_Example
  , putS = putS cmdS
  }

-- *** getS with fail

cmdSGetFail
  :: ( MonadTrans t
     , MonadFail (t Get)
     , Monad (t PutM)
     )
  => Serializer t (Some Cmd)
cmdSGetFail = Serializer
  { getS = getS opcode >>= \case
      OpCode_Int -> Some . Cmd_Int <$> lift getInt8
      OpCode_Bool -> fail "no parse"
  , putS = putS cmdS
  }

-- *** putS with fail

-- | Unused as PutM doesn't have @MonadFail@
-- >>> serializerPutFail = cmdPutFail @(ExceptT MyGetError)
-- No instance for (MonadFail PutM)
-- as expected
cmdSPutFail
  :: ( MonadTrans t
     , MonadFail (t PutM)
     , Monad (t Get)
     )
  => Serializer t (Some Cmd)
cmdSPutFail = Serializer
  { getS = getS cmdS
  , putS = \case
      Some (Cmd_Int i) -> putS opcode OpCode_Int >> lift (putInt8 i)
      Some (Cmd_Bool _b) -> fail "can't"
  }

-- * Elaborate

-- | Transformer for @Serializer@
newtype REST r e s m a = REST
  { _unREST :: ExceptT e (StateT s (ReaderT r m)) a }
  deriving
    ( Applicative
    , Functor
    , Monad
    , MonadError e
    , MonadReader r
    , MonadState s
    , MonadFail
    )

instance MonadTrans (REST r e s) where
  lift = REST . lift . lift . lift

-- | Runner for @REST@
restRunner
  :: Monad m
  => r
  -> s
  -> REST r e s m a
  -> m ((Either e a), s)
restRunner r s =
    (`runReaderT` r)
  . (`runStateT` s)
  . runExceptT
  . _unREST

runGRest
  :: Serializer (REST r e s) a
  -> r
  -> s
  -> ByteString
  -> Either (GetSerializerError e) a
runGRest serializer r s =
    transformGetError
  . second fst
  . runGetS
      serializer
      (restRunner r s)

runPRest
  :: Serializer (REST r e s) a
  -> r
  -> s
  -> a
  -> Either e ByteString
runPRest serializer r s =
    transformPutError
  . first fst
  . runPutS
      serializer
      (restRunner r s)

cmdSRest
  :: Serializer (REST Bool e Int) (Some Cmd)
cmdSRest = Serializer
  { getS = getS opcode >>= \case
      OpCode_Int -> do
        isTrue <- ask
        if isTrue
        then Some . Cmd_Int . (+1) <$> lift getInt8
        else Some . Cmd_Int <$> lift getInt8
      OpCode_Bool -> Some . Cmd_Bool <$> lift getBool
  , putS = \case
      Some (Cmd_Int i) -> do
        putS opcode OpCode_Int
        isTrue <- ask
        if isTrue
        then lift (putInt8 (i - 1))
        else lift (putInt8 i)
      Some (Cmd_Bool b) -> putS opcode OpCode_Bool >> lift (putBool b)
  }
