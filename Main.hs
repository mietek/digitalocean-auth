{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE UndecidableInstances #-}

import Control.Applicative ((<$>))
import Control.Lens ((&), (^?), (.~))
import Control.Monad.IO.Class (liftIO)
import Data.Aeson.Lens (_String, key)
import Data.Reflection (Given, give, given)
import Data.Text (Text)
import Network.Wai.Middleware.RequestLogger (logStdout)
import System.Environment (getEnv, getEnvironment)
import Web.Scotty (scotty)

import qualified Data.ByteString as BS
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.Lazy as LT
import qualified Network.HTTP.Types as H
import qualified Network.Wreq as C
import qualified Web.Scotty as S


redirect :: Text -> S.ActionM ()
redirect url = do
    S.redirect $ LT.fromStrict url


rejectBadRequest :: S.ActionM ()
rejectBadRequest = do
    S.html "<h1>400 Bad Request</h1>"
    S.status H.badRequest400


maybeParam :: (S.Parsable a) => LT.Text -> S.ActionM (Maybe a)
maybeParam name =
    S.rescue (Just <$> S.param name) $ const $
      return Nothing


addQuery :: (H.QueryLike a) => a -> Text -> Text
addQuery query url
    | BS.length str > 0 = T.decodeUtf8 $ BS.concat [T.encodeUtf8 url, sep, str]
    | otherwise         = url
  where
    str = H.renderQuery False $ H.toQuery query
    sep = case T.findIndex (== '?') url of
            Just _  -> "&"
            Nothing -> "?"


data Cfg = Cfg
    { clientId     :: Text
    , clientSecret :: Text
    , callbackUrl  :: Text
    , targetUrl    :: Text
    }
  deriving (Show)


postAccessTokenReq :: (Given Cfg) => Text -> IO (Maybe Text)
postAccessTokenReq code = do
    let opts = C.defaults
          & C.param "client_id"     .~ [clientId given]
          & C.param "client_secret" .~ [clientSecret given]
          & C.param "redirect_uri"  .~ [callbackUrl given]
          & C.param "grant_type"    .~ ["authorization_code"]
          & C.param "code"          .~ [code]
    res <- C.postWith opts "https://cloud.digitalocean.com/v1/oauth/token" BS.empty
    return $ res ^? C.responseBody . key "access_token" . _String


handleCallback :: (Given Cfg) => S.ActionM ()
handleCallback = do
    statep <- maybeParam "state"
    codep  <- maybeParam "code"
    let go more = do
          let base = case statep of
                Nothing    -> []
                Just state -> [("state" :: Text, state)]
              query = base ++ more
          redirect $ addQuery query $ targetUrl given
    case codep of
      Nothing   -> go [("error", "no_code")]
      Just code -> do
        mtoken <- liftIO $ postAccessTokenReq code
        case mtoken of
          Nothing    -> go [("error", "no_token")]
          Just token -> go [("token", token)]


main :: IO ()
main = do
    clientId     <- T.pack <$> getEnv "DIGITALOCEAN_CLIENT_ID"
    clientSecret <- T.pack <$> getEnv "DIGITALOCEAN_CLIENT_SECRET"
    callbackUrl  <- T.pack <$> getEnv "CALLBACK_URL"
    targetUrl    <- T.pack <$> getEnv "TARGET_URL"
    env          <- getEnvironment
    let port = maybe 8080 read $ lookup "PORT" env
        cfg  = Cfg
          { clientId
          , clientSecret
          , callbackUrl
          , targetUrl
          }
    give cfg $ scotty port $ do
      S.middleware logStdout
      S.get        "/callback" handleCallback
      S.notFound   rejectBadRequest
