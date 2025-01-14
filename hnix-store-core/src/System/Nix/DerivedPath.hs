{-# LANGUAGE OverloadedStrings #-}

module System.Nix.DerivedPath (
    OutputsSpec(..)
  , DerivedPath(..)
  , ParseOutputsError(..)
  , parseOutputsSpec
  , outputsSpecToText
  , parseDerivedPath
  , derivedPathToText
  ) where

import Data.Bifunctor (first)
import GHC.Generics (Generic)
import Data.Set (Set)
import Data.Text (Text)
import System.Nix.StorePath (StoreDir, StorePath, StorePathName, InvalidPathError)

import qualified Data.Set
import qualified Data.Text
import qualified System.Nix.StorePath

data OutputsSpec =
    OutputsSpec_All
  | OutputsSpec_Names (Set StorePathName)
  deriving (Eq, Generic, Ord, Show)

data DerivedPath =
    DerivedPath_Opaque StorePath
  | DerivedPath_Built StorePath OutputsSpec
  deriving (Eq, Generic, Ord, Show)

data ParseOutputsError =
    ParseOutputsError_InvalidPath InvalidPathError
  | ParseOutputsError_NoNames
  deriving (Eq, Ord, Show)

convertError
  :: Either InvalidPathError a
  -> Either ParseOutputsError a
convertError = first ParseOutputsError_InvalidPath

parseOutputsSpec :: Text -> Either ParseOutputsError OutputsSpec
parseOutputsSpec t
  | t == "*" = Right OutputsSpec_All
  | otherwise = do
  names <- mapM
             (convertError . System.Nix.StorePath.makeStorePathName)
             (Data.Text.splitOn "," t)
  if null names
    then Left ParseOutputsError_NoNames
    else Right $ OutputsSpec_Names (Data.Set.fromList names)

outputsSpecToText :: OutputsSpec -> Text
outputsSpecToText = \case
  OutputsSpec_All -> "*"
  OutputsSpec_Names ns ->
    Data.Text.intercalate "," (fmap System.Nix.StorePath.unStorePathName (Data.Set.toList ns))

parseDerivedPath
  :: StoreDir
  -> Text
  -> Either ParseOutputsError DerivedPath
parseDerivedPath root p =
  case Data.Text.breakOn "!" p of
    (s, r) ->
      if Data.Text.null r
      then DerivedPath_Opaque
           <$> (convertError $ System.Nix.StorePath.parsePathFromText root s)
      else DerivedPath_Built
           <$> (convertError $ System.Nix.StorePath.parsePathFromText root s)
           <*> parseOutputsSpec (Data.Text.drop (Data.Text.length "!") r)

derivedPathToText :: StoreDir -> DerivedPath -> Text
derivedPathToText root = \case
  DerivedPath_Opaque p ->
    System.Nix.StorePath.storePathToText root p
  DerivedPath_Built p os ->
    System.Nix.StorePath.storePathToText root p
    <> "!"
    <> outputsSpecToText os
