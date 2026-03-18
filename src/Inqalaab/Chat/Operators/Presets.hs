{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}

module Inqalaab.Chat.Operators.Presets where

import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as L
import Inqalaab.Chat.Operators
import Simplex.Messaging.Agent.Env.SQLite (ServerRoles (..), allRoles)
import Simplex.Messaging.Agent.Store.Entity
import Simplex.Messaging.Protocol (ProtocolType (..), SMPServer)

operatorSimpleXChat :: NewServerOperator
operatorSimpleXChat =
  ServerOperator
    { operatorId = DBNewEntity,
      operatorTag = Just OTSimplex,
      tradeName = "Inqalaab",
      legalName = Just "Your Healing Artist Limited",
      serverDomains = ["example.net", "inqalaab.chat"],
      conditionsAcceptance = CARequired Nothing,
      enabled = True,
      smpRoles = allRoles,
      xftpRoles = allRoles
    }

operatorFlux :: NewServerOperator
operatorFlux =
  ServerOperator
    { operatorId = DBNewEntity,
      operatorTag = Just OTFlux,
      tradeName = "Flux",
      legalName = Just "InFlux Technologies Limited",
      serverDomains = [],
      conditionsAcceptance = CARequired Nothing,
      enabled = False,
      smpRoles = ServerRoles {storage = False, proxy = True},
      xftpRoles = ServerRoles {storage = False, proxy = True}
    }

-- Inqalaab: 4 SMP + 4 XFTP self-hosted servers.
-- CRITICAL: Each (host, port) pair can only appear ONCE across ALL operator
-- server lists due to UNIQUE(user_id, host, port) on protocol_servers table.
-- The original SimpleX code had ~10 different SMP servers spread across
-- enabled/disabled/flux lists. We have 4 unique SMP servers — all go in
-- enabledInqalaabSMPServers. disabledInqalaabSMPServers and
-- fluxSMPServers_ must NOT duplicate any of these.

allPresetServers :: NonEmpty SMPServer
allPresetServers = enabledInqalaabSMPServers

inqalaabSMPServers :: [NewUserServer 'PSMP]
inqalaabSMPServers =
  map (presetServer' True) (L.toList enabledInqalaabSMPServers)

-- All 4 Inqalaab SMP servers (enabled)
enabledInqalaabSMPServers :: NonEmpty SMPServer
enabledInqalaabSMPServers =
  [ "smp://0000000000000000000000000000000000000000003=@smp.example.net:5223",
    "smp://0000000000000000000000000000000000000000015=@smp1.example.org:5223",
    "smp://0000000000000000000000000000000000000000006=@smp2.example.org",
    "smp://0000000000000000000000000000000000000000002=@smp3.example.org"
  ]

-- No disabled servers (would duplicate enabled list and violate UNIQUE constraint)
disabledInqalaabSMPServers :: NonEmpty SMPServer
disabledInqalaabSMPServers = enabledInqalaabSMPServers

-- No separate Flux SMP servers (all servers are under Inqalaab operator)
fluxSMPServers :: [NewUserServer 'PSMP]
fluxSMPServers = []

-- Required for type compatibility but not inserted into DB
fluxSMPServers_ :: NonEmpty SMPServer
fluxSMPServers_ = enabledInqalaabSMPServers

-- All 4 Inqalaab XFTP servers
fluxXFTPServers :: [NewUserServer 'PXFTP]
fluxXFTPServers =
  map
    (presetServer True)
    [ "xftp://0000000000000000000000000000000000000000008=@xftp.example.net:5233",
      "xftp://0000000000000000000000000000000000000000016=@xftp1.example.org",
      "xftp://0000000000000000000000000000000000000000004=@xftp2.example.org:5233",
      "xftp://0000000000000000000000000000000000000000019=@xftp3.example.org:5233"
    ]
