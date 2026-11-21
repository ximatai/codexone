use base64::{Engine, engine::general_purpose::STANDARD};
use codexone_storage::{AccountCredential, AccountCredentialContext};
use rusqlite::{Connection, Row, Transaction, params};
use serde::{Deserialize, Serialize};

use crate::{
    Error, Governance, Result, Target, VerifiedAuthorization, Work, Writer, check_revision,
    display_name, id, uuid,
};

#[derive(Clone, Copy, Debug, Deserialize, Serialize, Eq, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum AccountMode {
    Enabled,
    Draining,
    Disabled,
}

impl AccountMode {
    fn sql(self) -> &'static str {
        match self {
            Self::Enabled => "enabled",
            Self::Draining => "draining",
            Self::Disabled => "disabled",
        }
    }
}

#[derive(Clone, Copy, Debug, Serialize, Eq, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum AuthorizationState {
    Ready,
    Refreshing,
    RequiresAuth,
    AuthUncertain,
}

impl AuthorizationState {
    fn sql(self) -> &'static str {
        match self {
            Self::Ready => "ready",
            Self::Refreshing => "refreshing",
            Self::RequiresAuth => "requires_auth",
            Self::AuthUncertain => "auth_uncertain",
        }
    }
}

/// The persisted audit metadata. The administration DTO is assembled separately.
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Account {
    pub id: String,
    pub namespace: String,
    pub revision: i64,
    pub credential_version: i64,
    pub mode: AccountMode,
    pub authorization: AuthorizationState,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub refresh_intent: Option<String>,
    pub created_at_unix_seconds: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub display_name: Option<String>,
}

impl Account {
    fn context(&self) -> Result<AccountCredentialContext<'_>> {
        AccountCredentialContext::new(&self.id, &self.namespace, self.credential_version)
            .map_err(|_| Error::InvalidCommand)
    }

    fn advance(&mut self, authorization: AuthorizationState) -> Result<()> {
        let ceiling = if authorization == AuthorizationState::Refreshing {
            999_999
        } else {
            1_000_000
        };
        if self.revision >= ceiling {
            return Err(Error::Conflict);
        }
        self.revision += 1;
        self.authorization = authorization;
        Ok(())
    }
}

pub struct RefreshIntent {
    pub account: Account,
    pub credential: AccountCredential,
    intent: String,
}

impl<W: Writer> Governance<W> {
    pub async fn seal_verified(
        &self,
        target: Target,
        verified: VerifiedAuthorization,
    ) -> Result<Account> {
        let cipher = self.cipher.clone().ok_or(Error::Unavailable)?;
        self.writer
            .run(Work::Optional, move |db, now, _| {
                let tx = db.begin_immediate()?;
                let (account, action) = match target {
                    Target::Create => {
                        capacity(&tx, false, 1)?;
                        if tx.query_row("SELECT COUNT(*) FROM accounts", [], |row| {
                            row.get::<_, i64>(0)
                        })? >= 64
                        {
                            return Err(Error::Capacity);
                        }
                        let duplicate: bool = tx.query_row(
                            "SELECT EXISTS(SELECT 1 FROM accounts WHERE namespace=?)",
                            [&verified.namespace],
                            |row| row.get(0),
                        )?;
                        if duplicate {
                            return Err(Error::IdentityMismatch);
                        }
                        (
                            Account {
                                id: uuid()?,
                                namespace: verified.namespace,
                                revision: 1,
                                credential_version: 1,
                                mode: AccountMode::Disabled,
                                authorization: AuthorizationState::Ready,
                                refresh_intent: None,
                                created_at_unix_seconds: now,
                                display_name: None,
                            },
                            "create_verified",
                        )
                    }
                    Target::Reauthorize {
                        id: account_id,
                        revision,
                    } => {
                        id(&account_id)?;
                        let (mut account, _) = load(&tx, &account_id)?;
                        if account.revision != revision
                            || account.authorization == AuthorizationState::Refreshing
                            || account.credential_version >= 1_000_000
                        {
                            return Err(Error::Conflict);
                        }
                        if account.namespace != verified.namespace {
                            return Err(Error::IdentityMismatch);
                        }
                        capacity(&tx, false, 1)?;
                        account.advance(AuthorizationState::Ready)?;
                        account.credential_version += 1;
                        account.refresh_intent = None;
                        (account, "reauthorize_verified")
                    }
                };
                if now <= 0 {
                    return Err(Error::InvalidCommand);
                }
                let envelope = cipher
                    .seal(&verified.credential, &account.context()?)
                    .map_err(|_| Error::Unavailable)?;
                if action == "create_verified" {
                    tx.execute(
                        "INSERT INTO accounts (id,namespace,revision,credential_version,mode,
                      authorization,sealed_credential,refresh_intent,created_at_epoch,display_name)
                     VALUES(?,?,1,1,'disabled','ready',?,NULL,?,NULL)",
                        params![account.id, account.namespace, envelope, now],
                    )?;
                } else {
                    save(&tx, &account, &envelope)?;
                }
                audit(&tx, &account, action, now)?;
                tx.commit()?;
                Ok(account)
            })
            .await
    }

    pub async fn list_accounts(&self, after: Option<String>) -> Result<Vec<Account>> {
        if let Some(after) = &after {
            id(after)?;
        }
        self.writer
            .run(Work::Read, move |db, _, _| {
                let sql = format!("SELECT {COLUMNS} FROM accounts WHERE id>? ORDER BY id LIMIT 64");
                let mut statement = db.connection().prepare(&sql)?;
                let mut rows = statement.query([after.unwrap_or_default()])?;
                let mut accounts = Vec::new();
                while let Some(row) = rows.next()? {
                    accounts.push(decode(row)?.0);
                }
                Ok(accounts)
            })
            .await
    }

    pub async fn set_account_mode(
        &self,
        account_id: String,
        revision: i64,
        mode: AccountMode,
    ) -> Result<Account> {
        self.change_account(account_id, revision, AccountChange::Mode(mode))
            .await
    }

    pub async fn set_account_display_name(
        &self,
        account_id: String,
        revision: i64,
        name: Option<String>,
    ) -> Result<Account> {
        display_name(name.as_deref())?;
        check_revision(revision)?;
        self.change_account(account_id, revision, AccountChange::DisplayName(name))
            .await
    }

    async fn change_account(
        &self,
        account_id: String,
        revision: i64,
        change: AccountChange,
    ) -> Result<Account> {
        id(&account_id)?;
        let work = match change {
            AccountChange::Mode(AccountMode::Disabled | AccountMode::Draining) => Work::Restrict,
            _ => Work::Optional,
        };
        self.writer
            .run(work, move |db, now, optional_allowed| {
                let tx = db.begin_immediate()?;
                let (mut account, envelope) = load(&tx, &account_id)?;
                if account.revision != revision {
                    return Err(Error::Conflict);
                }
                account.advance(account.authorization)?;
                let (action, disabling) = match change {
                    AccountChange::Mode(mode) => {
                        let restricting = matches!(
                            (account.mode, mode),
                            (
                                AccountMode::Enabled,
                                AccountMode::Draining | AccountMode::Disabled
                            ) | (AccountMode::Draining, AccountMode::Disabled)
                        );
                        if !optional_allowed && !restricting {
                            return Err(Error::StoragePressure);
                        }
                        let disabling =
                            account.mode != AccountMode::Disabled && mode == AccountMode::Disabled;
                        account.mode = mode;
                        ("mode", disabling)
                    }
                    AccountChange::DisplayName(name) => {
                        account.display_name = name;
                        ("display_name", false)
                    }
                };
                capacity(&tx, disabling, 1)?;
                save(&tx, &account, &envelope)?;
                audit(&tx, &account, action, now)?;
                tx.commit()?;
                Ok(account)
            })
            .await
    }

    pub async fn force_stop(
        &self,
        account_id: String,
        revision: i64,
        cancel: impl FnOnce(&str) -> Result<usize> + Send + 'static,
    ) -> Result<usize> {
        id(&account_id)?;
        check_revision(revision)?;
        self.writer
            .run(Work::Read, move |db, _, _| {
                let (account, _) = load(db.connection(), &account_id)?;
                if account.revision != revision || account.mode != AccountMode::Disabled {
                    return Err(Error::Conflict);
                }
                cancel(&account_id)
            })
            .await
    }

    pub async fn credential_times(&self, account_id: String) -> Result<(Option<i64>, Option<i64>)> {
        id(&account_id)?;
        let cipher = self.cipher.clone();
        self.writer
            .run(Work::Read, move |db, _, _| {
                let connection = db.connection();
                let (account, envelope) = load(connection, &account_id)?;
                let updated = connection.query_row(
                    "SELECT MAX(at_epoch) FROM account_events WHERE account_id=? AND action IN
                 ('create_verified','reauthorize_verified','refresh_commit')",
                    [&account_id],
                    |row| row.get(0),
                )?;
                let expires = cipher
                    .and_then(|cipher| cipher.open(&envelope, &account.context().ok()?).ok())
                    .map(|credential| credential.expires_at_unix_seconds());
                Ok((updated, expires))
            })
            .await
    }

    /// An explicit refresh owner must close this intent through one of the terminal commands.
    /// A process interruption after commit is recovered as uncertain before admitting requests.
    pub async fn begin_refresh(&self, account_id: String, revision: i64) -> Result<RefreshIntent> {
        id(&account_id)?;
        let cipher = self.cipher.clone().ok_or(Error::Unavailable)?;
        self.writer
            .run(Work::Admission, move |db, now, _| {
                let tx = db.begin_immediate()?;
                let (mut account, envelope) = load(&tx, &account_id)?;
                if account.revision != revision
                    || account.authorization != AuthorizationState::Ready
                    || account.credential_version >= 1_000_000
                {
                    return Err(Error::Conflict);
                }
                capacity(&tx, false, 2)?;
                let credential = cipher
                    .open(&envelope, &account.context()?)
                    .map_err(|_| Error::Unavailable)?;
                account.advance(AuthorizationState::Refreshing)?;
                let intent = uuid()?;
                account.refresh_intent = Some(intent.clone());
                save(&tx, &account, &envelope)?;
                audit(&tx, &account, "refresh_begin", now)?;
                tx.commit()?;
                Ok(RefreshIntent {
                    account,
                    credential,
                    intent,
                })
            })
            .await
    }

    pub async fn finish_refresh(
        &self,
        intent: &RefreshIntent,
        verified: VerifiedAuthorization,
    ) -> Result<Account> {
        self.close_refresh(intent, RefreshResult::Verified(verified))
            .await
    }

    pub async fn fail_refresh(
        &self,
        intent: &RefreshIntent,
        authorization_required: bool,
    ) -> Result<Account> {
        self.close_refresh(intent, RefreshResult::Failed(authorization_required))
            .await
    }

    /// Only use with evidence that the provider never accepted the refresh.
    pub async fn abandon_refresh(&self, intent: &RefreshIntent) -> Result<Account> {
        self.close_refresh(intent, RefreshResult::NotCompleted)
            .await
    }

    async fn close_refresh(
        &self,
        intent: &RefreshIntent,
        result: RefreshResult,
    ) -> Result<Account> {
        let account_id = intent.account.id.clone();
        let version = intent.account.credential_version;
        let access_expires = intent.credential.expires_at_unix_seconds();
        let intent = intent.intent.clone();
        let cipher = self.cipher.clone();
        self.writer
            .run(Work::Critical, move |db, now, _| {
                let tx = db.begin_immediate()?;
                let (mut account, mut envelope) = load(&tx, &account_id)?;
                if account.authorization != AuthorizationState::Refreshing
                    || account.refresh_intent.as_deref() != Some(&intent)
                    || account.credential_version != version
                {
                    return Err(Error::Conflict);
                }
                let action = match result {
                    RefreshResult::Verified(verified) => {
                        if account.namespace != verified.namespace {
                            return Err(Error::IdentityMismatch);
                        }
                        account.advance(AuthorizationState::Ready)?;
                        account.credential_version += 1;
                        account.refresh_intent = None;
                        envelope = cipher
                            .ok_or(Error::Unavailable)?
                            .seal(&verified.credential, &account.context()?)
                            .map_err(|_| Error::Unavailable)?;
                        "refresh_commit"
                    }
                    RefreshResult::Failed(true) => {
                        account.advance(AuthorizationState::RequiresAuth)?;
                        "refresh_requires_auth"
                    }
                    RefreshResult::NotCompleted if access_expires > now => {
                        account.advance(AuthorizationState::Ready)?;
                        account.refresh_intent = None;
                        "refresh_not_completed"
                    }
                    RefreshResult::Failed(false) | RefreshResult::NotCompleted => {
                        account.advance(AuthorizationState::AuthUncertain)?;
                        "refresh_uncertain"
                    }
                };
                save(&tx, &account, &envelope)?;
                audit(&tx, &account, action, now)?;
                tx.commit()?;
                Ok(account)
            })
            .await
    }
}

enum AccountChange {
    Mode(AccountMode),
    DisplayName(Option<String>),
}

enum RefreshResult {
    Verified(VerifiedAuthorization),
    Failed(bool),
    NotCompleted,
}

/// Call inside startup recovery on the sole writer, before enabling account routing.
pub fn recover_refreshes(tx: &Transaction<'_>, now: i64) -> Result<()> {
    let sql = format!("SELECT {COLUMNS} FROM accounts WHERE authorization='refreshing' LIMIT 65");
    let mut statement = tx.prepare(&sql)?;
    let mut rows = statement.query([])?;
    let mut accounts = Vec::new();
    while let Some(row) = rows.next()? {
        accounts.push(decode(row)?);
    }
    if accounts.len() > 64 {
        return Err(Error::Unavailable);
    }
    for (mut account, envelope) in accounts {
        account.advance(AuthorizationState::AuthUncertain)?;
        save(tx, &account, &envelope)?;
        audit(tx, &account, "refresh_restart_uncertain", now)?;
    }
    Ok(())
}

const COLUMNS: &str = "id,namespace,revision,credential_version,mode,authorization,                       sealed_credential,refresh_intent,created_at_epoch,display_name";

fn load(db: &Connection, id: &str) -> Result<(Account, String)> {
    let sql = format!("SELECT {COLUMNS} FROM accounts WHERE id=?");
    let mut statement = db.prepare(&sql)?;
    let mut rows = statement.query([id])?;
    decode(rows.next()?.ok_or(Error::UnknownAccount)?)
}

fn decode(row: &Row<'_>) -> Result<(Account, String)> {
    let mode = match row.get_ref(4)?.as_str().map_err(|_| Error::Unavailable)? {
        "enabled" => AccountMode::Enabled,
        "draining" => AccountMode::Draining,
        "disabled" => AccountMode::Disabled,
        _ => return Err(Error::Unavailable),
    };
    let authorization = match row.get_ref(5)?.as_str().map_err(|_| Error::Unavailable)? {
        "ready" => AuthorizationState::Ready,
        "refreshing" => AuthorizationState::Refreshing,
        "requires_auth" => AuthorizationState::RequiresAuth,
        "auth_uncertain" => AuthorizationState::AuthUncertain,
        _ => return Err(Error::Unavailable),
    };
    let account = Account {
        id: row.get(0)?,
        namespace: row.get(1)?,
        revision: row.get(2)?,
        credential_version: row.get(3)?,
        mode,
        authorization,
        refresh_intent: row.get(7)?,
        created_at_unix_seconds: row.get(8)?,
        display_name: row.get(9)?,
    };
    let envelope: String = row.get(6)?;
    id(&account.id).map_err(|_| Error::Unavailable)?;
    check_revision(account.revision).map_err(|_| Error::Unavailable)?;
    display_name(account.display_name.as_deref()).map_err(|_| Error::Unavailable)?;
    account.context().map_err(|_| Error::Unavailable)?;
    if account.created_at_unix_seconds <= 0
        || account
            .refresh_intent
            .as_deref()
            .is_some_and(|value| id(value).is_err())
        || (authorization == AuthorizationState::Ready && account.refresh_intent.is_some())
        || (authorization == AuthorizationState::Refreshing && account.refresh_intent.is_none())
        || codexone_storage::AccountCredentialCipher::envelope_key_id(&envelope).is_err()
        || envelope.rsplit_once('.').is_none_or(|(_, body)| {
            STANDARD.decode(body).map_or(true, |decoded| {
                decoded.len() < 28 || STANDARD.encode(decoded) != body
            })
        })
    {
        return Err(Error::Unavailable);
    }
    Ok((account, envelope))
}

fn capacity(db: &Connection, disabling: bool, needed: i64) -> Result<()> {
    let occupied: i64 = db.query_row(
        "SELECT (SELECT COUNT(*) FROM account_events)
              + (SELECT COUNT(*) FROM accounts WHERE authorization='refreshing')",
        [],
        |row| row.get(0),
    )?;
    if occupied + needed > if disabling { 4160 } else { 4096 } {
        return Err(Error::Capacity);
    }
    Ok(())
}

fn save(tx: &Transaction<'_>, account: &Account, envelope: &str) -> Result<()> {
    tx.execute(
        "UPDATE accounts SET revision=?,credential_version=?,mode=?,authorization=?,sealed_credential=?,
         refresh_intent=?,display_name=? WHERE id=?",
        params![account.revision, account.credential_version, account.mode.sql(), account.authorization.sql(),
            envelope, account.refresh_intent, account.display_name, account.id],
    )?;
    Ok(())
}

fn audit(tx: &Transaction<'_>, account: &Account, action: &str, now: i64) -> Result<()> {
    if tx.query_row("SELECT COUNT(*) FROM account_events", [], |row| {
        row.get::<_, i64>(0)
    })? >= 4160
    {
        return Err(Error::Capacity);
    }
    let data = serde_json::to_string(account).map_err(|_| Error::Unavailable)?;
    tx.execute(
        "INSERT INTO account_events VALUES(?,?,?,?,?,?)",
        params![uuid()?, account.id, account.revision, action, data, now],
    )?;
    Ok(())
}

/// Read the account and its revision in the settings writer snapshot.
pub fn quota_account(db: &Connection, account_id: &str) -> Result<Account> {
    id(account_id)?;
    Ok(load(db, account_id)?.0)
}

/// Advance account CAS and record the settings command in its enclosing transaction.
pub fn change_quota_settings(
    tx: &Transaction<'_>,
    account_id: &str,
    revision: i64,
    action: &str,
    now: i64,
) -> Result<i64> {
    id(account_id)?;
    check_revision(revision)?;
    let (mut account, envelope) = load(tx, account_id)?;
    if account.revision != revision {
        return Err(Error::AccountConflict);
    }
    capacity(tx, false, 1)?;
    account.advance(account.authorization)?;
    save(tx, &account, &envelope)?;
    audit(tx, &account, action, now)?;
    Ok(account.revision)
}

/// Automatic failure disablement uses its preallocated job audit event.
pub fn bump_quota_revision(tx: &Transaction<'_>, account_id: &str) -> Result<()> {
    let (mut account, envelope) = load(tx, account_id)?;
    if account.advance(account.authorization).is_ok() {
        save(tx, &account, &envelope)?;
    }
    Ok(())
}
