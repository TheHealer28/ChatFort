{-# LANGUAGE CPP #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}

module Inqalaab.Chat.Terminal where

import Control.Monad
import qualified Data.List.NonEmpty as L
import Inqalaab.Chat (defaultChatConfig)
import Inqalaab.Chat.Controller
import Inqalaab.Chat.Core
import Inqalaab.Chat.Help (chatWelcome)
import Inqalaab.Chat.Library.Commands (_defaultNtfServers)
import Inqalaab.Chat.Operators
import Inqalaab.Chat.Operators.Presets (operatorSimpleXChat)
import Inqalaab.Chat.Options
import Inqalaab.Chat.Terminal.Input
import Inqalaab.Chat.Terminal.Output
import Simplex.FileTransfer.Client.Presets (defaultXFTPServers)
import Simplex.Messaging.Client (NetworkConfig (..), SMPProxyFallback (..), SMPProxyMode (..), defaultNetworkConfig)
import Simplex.Messaging.Util (raceAny_)
#if !defined(dbPostgres)
import Control.Exception (handle, throwIO)
import qualified Data.ByteArray as BA
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Database.SQLite.Simple (SQLError (..))
import qualified Database.SQLite.Simple as DB
import Inqalaab.Chat.Options.DB
import System.IO (hFlush, hSetEcho, stdin, stdout)
#endif

terminalChatConfig :: ChatConfig
terminalChatConfig =
  defaultChatConfig
    { presetServers =
        PresetServers
          { operators =
              [ PresetOperator
                  { operator = Just operatorSimpleXChat,
                    smp =
                      map
                        (presetServer True)
                        [ "smp://0000000000000000000000000000000000000000003=@smp.example.net:5223",
                          "smp://0000000000000000000000000000000000000000015=@smp1.example.org:5223",
                          "smp://0000000000000000000000000000000000000000006=@smp2.example.org",
                          "smp://0000000000000000000000000000000000000000002=@smp3.example.org"
                        ],
                    useSMP = 4,
                    xftp = map (presetServer True) $ L.toList defaultXFTPServers,
                    useXFTP = 3
                  }
              ],
            ntf = _defaultNtfServers,
            netCfg =
              defaultNetworkConfig
                { smpProxyMode = SPMUnknown,
                  smpProxyFallback = SPFAllowProtected
                }
          },
      deviceNameForRemote = "Inqalaab CLI"
    }

simplexChatTerminal :: WithTerminal t => ChatConfig -> ChatOpts -> t -> IO ()
simplexChatTerminal cfg options t = run options
  where
#if defined(dbPostgres)
    run opts =
      simplexChatCore cfg opts $ \u cc -> do
        ct <- newChatTerminal t opts
        when (firstTime cc) . printToTerminal ct $ chatWelcome u
        runChatTerminal ct cc opts
#else
    run opts@ChatOpts {coreOptions = coreOptions@CoreChatOpts {dbOptions}} =
      handle checkDBKeyError . simplexChatCore cfg opts $ \u cc -> do
        ct <- newChatTerminal t opts
        when (firstTime cc) . printToTerminal ct $ chatWelcome u
        runChatTerminal ct cc opts
      where
        checkDBKeyError :: SQLError -> IO ()
        checkDBKeyError e = case sqlError e of
          DB.ErrorNotADatabase -> do
            putStrLn $ "Database file is invalid or " <> if BA.null (dbKey dbOptions) then "encrypted." else "you passed an incorrect encryption key."
            run =<< getKeyOpts
          _ -> throwIO e
        getKeyOpts :: IO ChatOpts
        getKeyOpts = do
          putStr "Enter database encryption key (Ctrl-C to exit):"
          hFlush stdout
          hSetEcho stdin False
          key <- getLine
          hSetEcho stdin True
          putStrLn ""
          pure opts {coreOptions = coreOptions {dbOptions = dbOptions {dbKey = BA.convert $ encodeUtf8 $ T.pack key}}}
#endif

runChatTerminal :: ChatTerminal -> ChatController -> ChatOpts -> IO ()
runChatTerminal ct cc opts = raceAny_ [runTerminalInput ct cc, runTerminalOutput ct cc opts, runInputLoop ct cc]
