{-|
Description : Representation of Nix store paths.
-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE TypeInType #-} -- Needed for GHC 8.4.4 for some reason
module System.Nix.Internal.StorePath where
import System.Nix.Hash
  ( HashAlgorithm(Truncated, SHA256)
  , Digest
  , BaseEncoding(..)
  , encodeInBase
  , decodeBase
  , SomeNamedDigest
  )
import System.Nix.Internal.Base32 (dictNixBase32)

import Data.Bool (bool)
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8)
import qualified Data.Text as T
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import qualified Data.Char
import Data.Hashable (Hashable(..))
import Data.HashSet (HashSet)

import Data.Attoparsec.Text.Lazy (Parser, (<?>))

import qualified Data.Attoparsec.Text.Lazy
import qualified System.FilePath

-- | A path in a Nix store.
--
-- From the Nix thesis: A store path is the full path of a store
-- object. It has the following anatomy: storeDir/hashPart-name.
--
-- @storeDir@: The root of the Nix store (e.g. \/nix\/store).
--
-- See the 'StoreDir' haddocks for details on why we represent this at
-- the type level.
data StorePath = StorePath
  { -- | The 160-bit hash digest reflecting the "address" of the name.
    -- Currently, this is a truncated SHA256 hash.
    storePathHash :: !(Digest StorePathHashAlgo)
  , -- | The (typically human readable) name of the path. For packages
    -- this is typically the package name and version (e.g.
    -- hello-1.2.3).
    storePathName :: !StorePathName
  , -- | Root of the store
    storePathRoot :: !FilePath
  } deriving (Eq, Ord)

instance Hashable StorePath where
  hashWithSalt s (StorePath {..}) =
    s `hashWithSalt` storePathHash `hashWithSalt` storePathName

instance Show StorePath where
  show p = BC.unpack $ storePathToRawFilePath p

-- | The name portion of a Nix path.
--
-- 'unStorePathName' must only contain a-zA-Z0-9+._?=-, can't start
-- with a -, and must have at least one character (i.e. it must match
-- 'storePathNameRegex').
newtype StorePathName = StorePathName
  { -- | Extract the contents of the name.
    unStorePathName :: Text
  } deriving (Eq, Hashable, Ord)

-- | The hash algorithm used for store path hashes.
type StorePathHashAlgo = 'Truncated 20 'SHA256

-- | A set of 'StorePath's.
type StorePathSet = HashSet StorePath

-- | An address for a content-addressable store path, i.e. one whose
-- store path hash is purely a function of its contents (as opposed to
-- paths that are derivation outputs, whose hashes are a function of
-- the contents of the derivation file instead).
--
-- For backwards-compatibility reasons, the same information is
-- encodable in multiple ways, depending on the method used to add the
-- path to the store. These unfortunately result in separate store
-- paths.
data ContentAddressableAddress
  = -- | The path is a plain file added via makeTextPath or
    -- addTextToStore. It is addressed according to a sha256sum of the
    -- file contents.
    Text !(Digest 'SHA256)
  | -- | The path was added to the store via makeFixedOutputPath or
    -- addToStore. It is addressed according to some hash algorithm
    -- applied to the nar serialization via some 'NarHashMode'.
    Fixed !NarHashMode !SomeNamedDigest

-- | Schemes for hashing a nix archive.
--
-- For backwards-compatibility reasons, there are two different modes
-- here, even though 'Recursive' should be able to cover both.
data NarHashMode
  = -- | Require the nar to represent a non-executable regular file.
    RegularFile
  | -- | Hash an arbitrary nar, including a non-executable regular
    -- file if so desired.
    Recursive

makeStorePathName :: Text -> Either String StorePathName
makeStorePathName n = case validStorePathName n of
  True  -> Right $ StorePathName n
  False -> Left $ reasonInvalid n

reasonInvalid :: Text -> String
reasonInvalid n | n == ""            = "Empty name"
reasonInvalid n | (T.length n > 211) = "Path too long"
reasonInvalid n | (T.head n == '.')  = "Leading dot"
reasonInvalid _ | otherwise          = "Invalid character"

validStorePathName :: Text -> Bool
validStorePathName "" = False
validStorePathName n  = (T.length n <= 211)
                        && T.head n /= '.'
                        && T.all validateStorePathNameChar n

validateStorePathNameChar :: Char -> Bool
validateStorePathNameChar c =
  bool
  False
  (any ($ c)
   [ Data.Char.isLower
   , Data.Char.isDigit
   , Data.Char.isUpper
   , (`elem` ("+-._?=" :: String))])
  (Data.Char.isAscii c)

-- | Copied from @RawFilePath@ in the @unix@ package, duplicated here
-- to avoid the dependency.
type RawFilePath = ByteString

-- | Render a 'StorePath' as a 'RawFilePath'.
storePathToRawFilePath
  :: StorePath
  -> RawFilePath
storePathToRawFilePath StorePath {..} = BS.concat
    [ root
    , "/"
    , hashPart
    , "-"
    , name
    ]
  where
    root = BC.pack storePathRoot
    hashPart = encodeUtf8 $ encodeInBase Base32 storePathHash
    name = encodeUtf8 $ unStorePathName storePathName

-- | Render a 'StorePath' as a 'FilePath'.
storePathToFilePath
  :: StorePath
  -> FilePath
storePathToFilePath = BC.unpack . storePathToRawFilePath

-- | Render a 'StorePath' as a 'Text'.
storePathToText
  :: StorePath
  -> Text
storePathToText = T.pack . BC.unpack . storePathToRawFilePath

-- | Build `narinfo` suffix from `StorePath` which
-- can be used to query binary caches.
storePathToNarInfo
  :: StorePath
  -> BC.ByteString
storePathToNarInfo StorePath {..} = BS.concat
    [ encodeUtf8 $ encodeInBase Base32 storePathHash
    , ".narinfo"
    ]

-- | Parse `StorePath` from `BC.ByteString`, checking
-- that store directory matches `expectedRoot`.
parsePath
  :: FilePath
  -> BC.ByteString
  -> Either String StorePath
parsePath expectedRoot x =
  let
    (rootDir, fname) = System.FilePath.splitFileName . BC.unpack $ x
    (digestPart, namePart) = T.breakOn "-" $ T.pack fname
    digest = decodeBase Base32 digestPart
    name = makeStorePathName . T.drop 1 $ namePart
    --rootDir' = dropTrailingPathSeparator rootDir
    -- cannot use ^^ as it drops multiple slashes /a/b/// -> /a/b
    rootDir' = init rootDir
    storeDir = if expectedRoot == rootDir'
      then Right rootDir'
      else Left $ "Root store dir mismatch, expected" <> expectedRoot <> "got" <> rootDir'
  in
    StorePath <$> digest <*> name <*> storeDir

pathParser :: FilePath -> Parser StorePath
pathParser expectedRoot = do
  _ <- Data.Attoparsec.Text.Lazy.string (T.pack expectedRoot)
    <?> "Store root mismatch" -- e.g. /nix/store

  _ <- Data.Attoparsec.Text.Lazy.char '/'
    <?> "Expecting path separator"

  digest <- decodeBase Base32
    <$> Data.Attoparsec.Text.Lazy.takeWhile1 (`elem` dictNixBase32)
    <?> "Invalid Base32 part"

  _ <- Data.Attoparsec.Text.Lazy.char '-'
    <?> "Expecting dash (path name separator)"

  c0 <- Data.Attoparsec.Text.Lazy.satisfy (\c -> c /= '.' && validateStorePathNameChar c)
    <?> "Leading path name character is a dot or invalid character"

  rest <- Data.Attoparsec.Text.Lazy.takeWhile validateStorePathNameChar
    <?> "Path name contains invalid character"

  let name = makeStorePathName $ T.cons c0 rest

  either fail return
    $ StorePath <$> digest <*> name <*> pure expectedRoot
