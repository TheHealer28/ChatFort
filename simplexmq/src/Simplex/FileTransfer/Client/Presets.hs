{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.FileTransfer.Client.Presets where

import Data.List.NonEmpty (NonEmpty)
import Simplex.Messaging.Protocol (XFTPServerWithAuth)

defaultXFTPServers :: NonEmpty XFTPServerWithAuth
defaultXFTPServers =
  [ "xftp://0000000000000000000000000000000000000000008=@xftp.example.net:5233",
    "xftp://0000000000000000000000000000000000000000016=@xftp1.example.org",
    "xftp://0000000000000000000000000000000000000000004=@xftp2.example.org:5233",
    "xftp://0000000000000000000000000000000000000000019=@xftp3.example.org:5233"
  ]
