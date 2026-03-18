{-# LANGUAGE CPP #-}

module Inqalaab.Chat.Store
  ( DBStore,
    StoreError (..),
    ChatLockEntity (..),
    UserMsgReceiptSettings (..),
    UserContactLink (..),
    GroupLink (..),
    GroupLinkInfo (..),
    AddressSettings (..),
    AutoAccept (..),
    createChatStore,
    migrations, -- used in tests
    withTransaction,
  )
where

import Inqalaab.Chat.Store.Groups (GroupLink (..))
import Inqalaab.Chat.Store.Profiles
import Inqalaab.Chat.Store.Shared
import Simplex.Messaging.Agent.Store.Common (DBStore (..), withTransaction)
import Simplex.Messaging.Agent.Store.Interface (DBOpts, createDBStore)
import Simplex.Messaging.Agent.Store.Shared (MigrationConfig, MigrationError)
#if defined(dbPostgres)
import Inqalaab.Chat.Store.Postgres.Migrations
#else
import Inqalaab.Chat.Store.SQLite.Migrations
#endif

createChatStore :: DBOpts -> MigrationConfig -> IO (Either MigrationError DBStore)
createChatStore dbCreateOpts = createDBStore dbCreateOpts migrations
