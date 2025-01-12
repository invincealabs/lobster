{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeSynonymInstances #-}
--
-- Snap.hs --- Snap utilities for the V3SPA web service.
--
-- Copyright (C) 2014, Galois, Inc.
-- All Rights Reserved.
--
-- Released under the "BSD3" license.  See the file "LICENSE"
-- for details.
--

module V3SPA.Server.Snap where

import Control.Applicative (Applicative, Alternative, (<$>))
import Control.Error
import Control.Monad.CatchIO (MonadCatchIO)
import Control.Monad.Reader
import Data.Aeson
import Data.Monoid ((<>))
import Network.HTTP.Media (MediaType, RenderHeader, (//), matches, parseAccept, renderHeader)
import Snap

import Lobster.Core (Span(..), Error(..))
import V3SPA.Server.Version

import qualified Data.ByteString          as BS
import qualified Data.ByteString.Char8    as C
import qualified Data.ByteString.Lazy     as LBS
import qualified Data.Text.Lazy           as T
import qualified Data.Text.Lazy.Encoding  as E
import qualified Data.Aeson.Encode.Pretty as AP

class IsError a where
  toError :: a -> Error Span

instance IsError String where
  toError = MiscError

instance IsError (Error Span) where
  toError = id

-- | Snap monad extended with a "Reader" for configuration data.
--
-- TODO: Add something here to collect warnings.
newtype V3Snap a = V3Snap { runV3Snap :: ReaderT Options Snap a }
  deriving ( Functor, Applicative, Alternative, Monad, MonadPlus
           , MonadIO, MonadCatchIO, MonadSnap, MonadReader Options)

-- | Read the request body with a 100MiB limit.
readBody :: MonadSnap m => m LBS.ByteString
readBody = readRequestBody (100 * 1024 * 1024)

-- | Read the request body as a string.
readBodyString :: MonadSnap m => m String
readBodyString = T.unpack . E.decodeUtf8 <$> readBody

-- | Encode a result as JSON and write it to the response.
writeJSON :: (MonadSnap m, ToJSON a) => a -> m ()
writeJSON x = do
  setContentType' resultType
  writeLBS (AP.encodePretty' conf x)
  writeLBS "\r\n"


----------------------------------------------------------------------
-- Media Types

resultType :: MediaType
resultType = "application" // "vnd.v3spa.result+json"

formMultipart :: MediaType
formMultipart = "multipart" // "form-data"

lobsterType :: MediaType
lobsterType = "application" // "vnd.lobster"

selinuxJsonType :: MediaType
selinuxJsonType = "application" // "vnd.v3spa.selinux+json"


----------------------------------------------------------------------
-- Request Handling

-- | Get a required parameter. If the parameter is missing or cannot be decoded
-- using UTF8, sends an error response and skips the rest of the calling
-- handler.
getRequiredParam :: MonadSnap m => BS.ByteString -> m BS.ByteString
getRequiredParam name = do
  p <- getParam name
  handleError 400 (note ("Required parameter, '" <> C.unpack name <> "', is missing") p)

-- | Like `getRequiredParam`, but also takes a function to parse the parameter.
parseRequiredParam :: (IsError e, MonadSnap m) => (BS.ByteString -> Either e a) -> BS.ByteString -> m a
parseRequiredParam f name = do
  p <- getRequiredParam name
  handleError 400 (f p)

-- | Like `parseRequiredParam`, except that if the parameter does not exist then
-- the parsing function may provide a default value.
parseParam :: (IsError e, MonadSnap m) => (Maybe BS.ByteString -> Either e a) -> BS.ByteString -> m a
parseParam f name = do
  p <- getParam name
  handleError 400 (f p)

requireContentType :: MonadSnap m => MediaType -> m ()
requireContentType requiredType = do
  contentType <- getContentType
  if matches contentType requiredType
  then return ()
  else do
    modifyResponse $ setResponseCode 415  -- Unsupported Media Type
    writeBS ("Expected " <> renderHeader requiredType <> ", but got " <> renderHeader contentType)
    getResponse >>= finishWith

getContentType :: MonadSnap m => m MediaType
getContentType = do
  req <- getRequest
  let maybeContentType = getHeader "Content-Type" req >>= parseAccept
  let defaultType = "application" // "octet-stream"
  return $ fromMaybe defaultType maybeContentType

setContentType' :: (MonadSnap m, RenderHeader h) => h -> m ()
setContentType' t = do
  modifyResponse $ setHeader "Content-Type" (renderHeader t)


----------------------------------------------------------------------
-- Response Handling

-- | Create a response object given a result and list of errors.
mkResp :: ToJSON a => a -> [Error Span] -> Value
mkResp result errors =
  object [ "version" .= version
         , "result"  .= result
         , "errors"  .= errors
         ]

respondOk :: MonadSnap m => m ()
respondOk = modifyResponse $ setResponseCode 200

respondCreated :: MonadSnap m => BS.ByteString -> m ()
respondCreated resourcePath = do
  modifyResponse $ setResponseCode 201
                 . addHeader "Location" resourcePath

-- | Send a successful response.
respond :: (MonadSnap m, ToJSON a) => a -> m ()
respond x = writeJSON (mkResp x [])

-- | Send an error response as JSON from an error object.
sendError :: MonadSnap m => Value -> m a
sendError obj = do
  writeJSON obj
  r <- getResponse
  finishWith r

-- | Run an action that may fail in the "V3Snap" monad,
-- catching errors and returning them as a JSON response.
hoistErr :: MonadSnap m => Either (Error Span) a -> m a
hoistErr (Left e)  = sendError (mkResp Null [e])
hoistErr (Right x) = return x

-- | Run an action that may fail with a string in the
-- "V3Snap" monad, catching errors and returning them
-- as a JSON response.
hoistMiscErr :: MonadSnap m => Either String a -> m a
hoistMiscErr = hoistErr . fmapL MiscError

handleError :: (IsError e, MonadSnap m) => Int -> Either e a -> m a
handleError statusCode (Left e) = do
  modifyResponse $ setResponseCode statusCode
  sendError (mkResp Null [toError e])
handleError _ (Right x) = return x

-- | Pretty JSON configuration for parsed Lobster.
conf :: AP.Config
conf = AP.defConfig
  { AP.confIndent  = 2
  , AP.confCompare = AP.keyOrder
                       [ "name", "class", "args", "ports"
                       , "connections", "subdomains"
                       , "left", "right", "connection"
                       ]
  }

----------------------------------------------------------------------
-- Option Processing

-- | Web service options (from command line).
data Options = Options
  { optionDataDir :: Maybe FilePath
  } deriving Show

-- | Default options.
defaultOptions :: Options
defaultOptions = Options
  { optionDataDir = Nothing
  }
