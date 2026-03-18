{-# LANGUAGE CPP #-}

module Inqalaab.Chat.Options.DB

#if defined(dbPostgres)
  ( module Inqalaab.Chat.Options.Postgres,
    FromField (..),
    ToField (..),
  )
  where
import Inqalaab.Chat.Options.Postgres
import Database.PostgreSQL.Simple.FromField (FromField (..))
import Database.PostgreSQL.Simple.ToField (ToField (..))

#else
  ( module Inqalaab.Chat.Options.SQLite,
    FromField (..),
    ToField (..),
  )
  where
import Inqalaab.Chat.Options.SQLite
import Database.SQLite.Simple.FromField (FromField (..))
import Database.SQLite.Simple.ToField (ToField (..))

#endif
