{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE LambdaCase #-}

module Components.Permission
    ( allowed
    , permissions
    , Perm(..)
    , perm
    , Permissions
    , UserPermissions
    -- * Pure Permission Changes
    , allows
    , grant
    , revoke
    -- * Acid Queries/Updates
    , GrantU(..)
    , RevokeU(..)
    , UserPerms(..)
    ) where

import Control.Applicative
import Control.Lens
import Control.Monad.Acid
import Control.Monad.Reader
import Data.Acid hiding (query, update)
import Data.Map (Map)
import Data.SafeCopy
import Data.Semigroup
import Data.Set (Set)
import Data.Text (Text)
import GHC.TypeLits (KnownSymbol)
import Network.Voco.Combinators
import Network.Voco.Core (Bot)
import Network.Yak
import Network.Yak.Client
import Orphans ()

import qualified Data.Set as Set
import qualified Data.Attoparsec.Text as A

data Perm =
    SetPermissions -- ^ "set-perms"
    deriving (Eq, Ord, Show, Read)

permDict :: [(Perm, Text)]
permDict = [(SetPermissions, "set-perms")]

perm :: A.Parser Perm
perm = A.choice . map (\(p,s) -> p <$ A.string s) $ permDict

newtype Permissions =
    Perms (Set Perm)
    deriving (Semigroup, Monoid)

newtype UserPermissions =
    UPerms (Map Host Permissions)
    deriving (Semigroup, Monoid)

makeWrapped ''UserPermissions
deriveSafeCopy 0 'base ''Perm
deriveSafeCopy 0 'base ''Permissions
deriveSafeCopy 0 'base ''UserPermissions

allows :: Permissions -> Perm -> Bool
allows (Perms ps) p = p `Set.member` ps

grant :: Permissions -> Perm -> Permissions
grant (Perms ps) p = (Perms $ Set.insert p ps)

revoke :: Permissions -> Perm -> Permissions
revoke (Perms ps) p = (Perms $ Set.delete p ps)

grantU :: Host -> Perm -> Update UserPermissions ()
grantU h p = _Wrapped . at h . _Just %= flip grant p

revokeU :: Host -> Perm -> Update UserPermissions ()
revokeU h p = _Wrapped . at h . _Just %= flip revoke p

userPerms :: Host -> Query UserPermissions (Maybe Permissions)
userPerms h = view $ _Wrapped . at h

makeAcidic ''UserPermissions ['grantU, 'revokeU, 'userPerms]

-- | Guard a bot over an IRC message using with a collection of required
-- permissions. The bot will fail as long as any permission in the given
-- 'Foldable' is not present for the user triggering it, as determined by the
-- message prefix.
allowed ::
       (AcidMember UserPermissions s, MonadAcid s m, Foldable t, KnownSymbol c)
    => t Perm
    -> Bot m (Msg c p) o
    -> Bot m (Msg c p) o
allowed ps b = do
    i <- msgPrefix <$> query
    case i of
        Just (PrefixUser h) -> do
            uperms <- queryAcid $ UserPerms h
            case uperms of
                Just hps -> do
                    guard (all (hps `allows`) ps)
                    b
                _ -> empty
        _ -> empty

data PermCmd
    = Grant Host
            Perm
    | Revoke Host
             Perm
    deriving (Eq, Show, Ord, Read)

permCmd :: A.Parser PermCmd
permCmd =
    A.choice
        [ Grant <$> (A.string ":grant" *> A.skipSpace *> host) <*>
          (A.skipSpace *> perm)
        , Revoke <$> (A.string ":revoke" *> A.skipSpace *> host) <*>
          (A.skipSpace *> perm)
        ]
  where
    host = do
        n <- A.takeTill (A.inClass " .!@\r\n")
        p <- A.peekChar
        case p of
            Just c
                | c == '.' -> empty
            _ ->
                Host n <$>
                optional (A.char '!' *> A.takeTill (A.inClass " @\r\n")) <*>
                optional (A.char '@' *> A.takeTill (A.inClass " \r\n"))

-- | A bot capable of updating permissions, which can be used by any user with
-- the 'SetPermissions' permission. See the 'Perm' type ('permDict') for
-- legal permissions.
--
-- Syntax:
--
-- > :grant <host> <permission>
-- > :revoke <host> <permission>
permissions ::
       (AcidMember UserPermissions s, MonadAcid s m, Monad m)
    => Bot m Privmsg ()
permissions =
    allowed [SetPermissions] . on (view privmsgMessage) . parsedMsg permCmd $
    query >>= \case
        Grant h p -> updateAcid $ GrantU h p
        Revoke h p -> updateAcid $ RevokeU h p