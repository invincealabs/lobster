{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE OverloadedStrings #-}
--
-- SELinux.hs --- SELinux importer for the V3SPA web service.
--
-- Copyright (C) 2013, Galois, Inc.
-- All Rights Reserved.
--
-- Released under the "BSD3" license.  See the file "LICENSE"
-- for details.
--

module V3SPA.Server.Import.SELinux
  ( importModules
  ) where

import Control.Applicative ((<$>), (<*>))
import Control.Error
import Control.Lens
import Control.Monad.Reader
import Data.Aeson
import System.Directory (doesFileExist)
import System.FilePath ((</>))

import SCD.M4.ModuleFiles
import Snap

import CoreSyn (showLobsterBS)
import V3SPA.Server.Snap

import qualified Data.ByteString.Lazy as LBS
import qualified SCD.M4.Syntax        as M4
import qualified M4ToLobster          as M

data SELinuxImportRequest = SELinuxImportRequest
  { seReqRefpolicy :: String
  , seReqModules   :: [ModuleSource]
  } deriving Show

instance FromJSON SELinuxImportRequest where
  parseJSON (Object v) =
    SELinuxImportRequest <$> v .: "refpolicy"
                         <*> v .: "modules"
  parseJSON _ = mzero

-- XXX kind of lousy orphan instance here
instance FromJSON ModuleSource where
  parseJSON (Object v) =
    ModuleSource <$> v .: "name"
                 <*> v .: "if"
                 <*> v .: "te"
                 <*> v .: "fc"
  parseJSON _ = mzero

importModule :: MonadSnap m => M4.Policy -> ModuleSource -> m M4.Policy
importModule p modSrc = do
  m <- hoistMiscErr $ readPolicyModuleSource modSrc
  return $ addPolicyModule m p

--- | Given an import request, produces a list of pairs containing module names
-- paired with Lobster source code.
importModules :: SELinuxImportRequest -> V3Snap LBS.ByteString
importModules req = do
  refPath <- refPolicyDir (seReqRefpolicy req)
  policy0 <- liftIO $ readPolicy Nothing refPath
  policy1 <- foldM importModule policy0 (seReqModules req)
  let subAttrFile = refPath ++ "/subattributes"
  ok      <- liftIO $ doesFileExist subAttrFile
  subAttr <- liftIO $
    if not ok then return []
    else fmap M.parseSubAttributes (readFile subAttrFile)
  let eitherLsr = M.toLobster subAttr policy1
  lsr     <- hoistMiscErr (eitherLsr & _Left %~ show)
  return $ showLobsterBS lsr

-- | Return the directory that contains reference policy versions.
refPolicyBaseDir :: V3Snap FilePath
refPolicyBaseDir = do
  dataDir <- fromMaybe "." <$> asks optionDataDir
  return $ dataDir </> "refpolicy"

-- | Return the directory for a reference policy by name.
refPolicyDir :: String -> V3Snap FilePath
refPolicyDir name = (</> name) <$> refPolicyBaseDir
