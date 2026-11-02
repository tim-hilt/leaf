//! Sign-in with Google Drive and OneDrive (ADR-0010): the authorization code
//! flow with PKCE (RFC 7636), which a public client needs no secret for. The
//! core makes the verifier and the state, the consent page's address, checks
//! the redirect and exchanges its code for a refresh token. A client only
//! shows the page and hands the redirect back. The providers' endpoints and
//! scopes are here, and the storage modules take their token endpoints from
//! here too.

use crate::cloud_http::agent;
use crate::percent::{decode, encode};
use base64::prelude::{BASE64_URL_SAFE_NO_PAD, Engine};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::fmt;
use ureq::Agent;
use ureq::http::Request;

/// A Cloud Provider behind OAuth.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OAuthProvider {
    /// The `Leaf` folder in My Drive.
    GoogleDrive,
    /// `Apps/Leaf`, personal accounts only.
    OneDrive,
}

/// What a provider's OAuth needs, see `OAuthProvider::endpoints`.
struct Endpoints {
    authorization: &'static str,
    token: &'static str,
    /// What the consent page asks for. The first gives access to the files
    /// Leaf creates, and the consent has to include it.
    scopes: &'static [&'static str],
    /// What the page asks for besides the standard parameters, e.g. a refresh token.
    parameters: &'static [(&'static str, &'static str)],
    /// What the redirect URI is after the app's URL scheme.
    redirect_suffix: &'static str,
}

/// Always asks for offline access and for consent, so Google always hands out
/// a refresh token.
const GOOGLE: Endpoints = Endpoints {
    authorization: "https://accounts.google.com/o/oauth2/v2/auth",
    token: "https://oauth2.googleapis.com/token",
    scopes: &["https://www.googleapis.com/auth/drive.file"],
    parameters: &[("access_type", "offline"), ("prompt", "consent")],
    redirect_suffix: ":/oauth2redirect",
};

/// The `consumers` endpoint: personal accounts only. `offline_access` gives
/// the refresh token.
const MICROSOFT: Endpoints = Endpoints {
    authorization: "https://login.microsoftonline.com/consumers/oauth2/v2.0/authorize",
    token: "https://login.microsoftonline.com/consumers/oauth2/v2.0/token",
    scopes: &["Files.ReadWrite.AppFolder", "offline_access"],
    parameters: &[("prompt", "select_account")],
    redirect_suffix: "://auth",
};

impl OAuthProvider {
    fn endpoints(self) -> &'static Endpoints {
        match self {
            Self::GoogleDrive => &GOOGLE,
            Self::OneDrive => &MICROSOFT,
        }
    }

    /// Where the provider turns a code or a refresh token into an access token.
    pub(crate) fn token_endpoint(self) -> &'static str {
        self.endpoints().token
    }
}

/// One attempt at signing in with a provider. It makes its own verifier and
/// state, which the redirect has to carry back.
pub struct SignIn {
    provider: OAuthProvider,
    client_id: String,
    /// The URL scheme the app registers for the redirect.
    redirect_scheme: String,
    verifier: String,
    state: String,
}

impl SignIn {
    /// An attempt with the public OAuth client `client_id` of the app, whose
    /// redirect comes back to `redirect_scheme`.
    pub fn new(provider: OAuthProvider, client_id: &str, redirect_scheme: &str) -> Self {
        Self::with_secrets(provider, client_id, redirect_scheme, random(), random())
    }

    fn with_secrets(
        provider: OAuthProvider,
        client_id: &str,
        redirect_scheme: &str,
        verifier: String,
        state: String,
    ) -> Self {
        Self {
            provider,
            client_id: client_id.to_owned(),
            redirect_scheme: redirect_scheme.to_owned(),
            verifier,
            state,
        }
    }

    fn redirect_uri(&self) -> String {
        format!(
            "{}{}",
            self.redirect_scheme,
            self.provider.endpoints().redirect_suffix
        )
    }

    /// The consent page to open. It asks for the files Leaf creates, and
    /// carries the PKCE challenge of the verifier.
    pub fn authorization_url(&self) -> String {
        let endpoints = self.provider.endpoints();
        let challenge = BASE64_URL_SAFE_NO_PAD.encode(Sha256::digest(&self.verifier));
        let redirect_uri = self.redirect_uri();
        let scopes = endpoints.scopes.join(" ");
        let standard = [
            ("client_id", self.client_id.as_str()),
            ("redirect_uri", redirect_uri.as_str()),
            ("response_type", "code"),
            ("scope", scopes.as_str()),
            ("code_challenge", challenge.as_str()),
            ("code_challenge_method", "S256"),
            ("state", self.state.as_str()),
        ];
        let query: Vec<String> = standard
            .into_iter()
            .chain(endpoints.parameters.iter().copied())
            .map(|(name, value)| format!("{name}={}", encode(value)))
            .collect();
        format!("{}?{}", endpoints.authorization, query.join("&"))
    }

    /// The refresh token that the redirect to `callback` leads to, which is
    /// exchanged with the provider. `Cancelled` if the user declined on the
    /// consent page, `MissingPermission` if the consent left out the files
    /// Leaf creates, `Unreachable` without an answer from the provider.
    pub fn refresh_token(&self, callback: &str) -> Result<String, OAuthError> {
        self.exchange(&agent(false), self.provider.token_endpoint(), callback)
    }

    /// `refresh_token`, sent over `agent` to the token endpoint at `token_url`.
    fn exchange(
        &self,
        agent: &Agent,
        token_url: &str,
        callback: &str,
    ) -> Result<String, OAuthError> {
        let code = self.code(callback)?;
        let redirect_uri = self.redirect_uri();
        let form = [
            ("client_id", self.client_id.as_str()),
            ("code", code.as_str()),
            ("code_verifier", self.verifier.as_str()),
            ("grant_type", "authorization_code"),
            ("redirect_uri", redirect_uri.as_str()),
        ]
        .map(|(name, value)| format!("{name}={}", encode(value)))
        .join("&");
        let request = Request::builder()
            .method("POST")
            .uri(token_url)
            .header("Content-Type", "application/x-www-form-urlencoded")
            .body(form.as_bytes())
            .map_err(|_| OAuthError::Unreachable)?;
        let mut response = agent.run(request).map_err(|_| OAuthError::Unreachable)?;
        if response.status().as_u16() != 200 {
            return Err(OAuthError::AccessDenied);
        }
        let body = response
            .body_mut()
            .read_to_string()
            .map_err(|_| OAuthError::Unreachable)?;
        let answer: Value = serde_json::from_str(&body).map_err(|_| OAuthError::AccessDenied)?;
        let scope = answer["scope"].as_str().ok_or(OAuthError::AccessDenied)?;
        let refresh_token = answer["refresh_token"]
            .as_str()
            .ok_or(OAuthError::AccessDenied)?;
        if !self.grants(scope) {
            return Err(OAuthError::MissingPermission);
        }
        Ok(refresh_token.to_owned())
    }

    /// The authorization code that the redirect to `callback` carries.
    fn code(&self, callback: &str) -> Result<String, OAuthError> {
        let query = callback
            .split_once('?')
            .and_then(|(_, rest)| rest.split('#').next())
            .unwrap_or_default();
        let params: Vec<(&str, String)> = query
            .split('&')
            .filter_map(|pair| pair.split_once('='))
            .map(|(name, value)| (name, decode(value)))
            .collect();
        // The first of a name counts.
        let param = |name: &str| {
            params
                .iter()
                .find(|(key, _)| *key == name)
                .map(|(_, value)| value.as_str())
        };
        if let Some(error) = param("error") {
            return Err(if error == "access_denied" {
                OAuthError::Cancelled
            } else {
                OAuthError::AccessDenied
            });
        }
        match (param("state"), param("code")) {
            (Some(state), Some(code)) if state == self.state => Ok(code.to_owned()),
            _ => Err(OAuthError::AccessDenied),
        }
    }

    /// Whether `granted`, the scope of a token response, includes access to
    /// the files Leaf creates. Providers may qualify scopes with a resource URL.
    fn grants(&self, granted: &str) -> bool {
        let needed = self.provider.endpoints().scopes[0].to_lowercase();
        let qualified = format!("/{needed}");
        granted
            .split_whitespace()
            .map(str::to_lowercase)
            .any(|scope| scope == needed || scope.ends_with(&qualified))
    }
}

/// Why signing in failed, see `SignIn::refresh_token`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OAuthError {
    /// The user declined on the consent page.
    Cancelled,
    /// The redirect isn't the answer to this attempt, or the provider refused the code.
    AccessDenied,
    /// The consent left out access to the files Leaf creates.
    MissingPermission,
    /// No answer from the provider: no network, or a server that is down.
    Unreachable,
}

/// The variant's name; clients word the message for the user.
impl fmt::Display for OAuthError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "{self:?}")
    }
}

impl std::error::Error for OAuthError {}

/// 32 random bytes, base64url without padding: as long as a PKCE verifier
/// needs to be, and as unguessable as a state.
fn random() -> String {
    let mut bytes = [0; 32];
    getrandom::fill(&mut bytes).expect("the OS has a random number generator");
    BASE64_URL_SAFE_NO_PAD.encode(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cloud_http::fake::{Api, Auth, Consent, Reply, Request as Call, Server, nothing};
    use std::collections::HashMap;

    const CLIENT: &str = "123-abc.apps.googleusercontent.com";
    const GOOGLE_SCHEME: &str = "com.googleusercontent.apps.123-abc";
    const ONEDRIVE_SCHEME: &str = "msauth.com.timhilt.leaf";
    /// The verifier of RFC 7636, appendix B, whose challenge is `CHALLENGE`.
    const VERIFIER: &str = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
    const CHALLENGE: &str = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM";
    const STATE: &str = "xyz";

    fn attempt(provider: OAuthProvider, scheme: &str) -> SignIn {
        SignIn::with_secrets(
            provider,
            CLIENT,
            scheme,
            VERIFIER.to_owned(),
            STATE.to_owned(),
        )
    }

    /// The address of `url` without its query, and its query, decoded.
    fn page(url: &str) -> (String, HashMap<String, String>) {
        let (address, query) = url.split_once('?').unwrap();
        let query = query
            .split('&')
            .map(|pair| {
                let (name, value) = pair.split_once('=').unwrap();
                (name.to_owned(), decode(value))
            })
            .collect();
        (address.to_owned(), query)
    }

    /// A token endpoint that answers nothing but the token requests.
    struct TokenOnly(Auth);

    impl Api for TokenOnly {
        fn auth(&mut self) -> &mut Auth {
            &mut self.0
        }

        fn route(&mut self, _: &Call, _: &str) -> Reply {
            nothing(404)
        }
    }

    /// The consent to `attempt`, granting `scope`.
    fn consent(attempt: &SignIn, scope: &str, refresh: Option<&str>) -> Consent {
        Consent {
            code: "4/0Abc".to_owned(),
            verifier: VERIFIER.to_owned(),
            redirect_uri: attempt.redirect_uri(),
            scope: scope.to_owned(),
            refresh: refresh.map(str::to_owned),
        }
    }

    /// Exchanges the code of a redirect to `callback` at a fake token
    /// endpoint that the consent `consent` gives.
    fn exchange_at_fake(
        attempt: &SignIn,
        consent: Consent,
        callback: &str,
    ) -> Result<String, OAuthError> {
        let server = Server::start(TokenOnly(Auth::new(CLIENT, "")));
        server.state.lock().unwrap().0.consent = Some(consent);
        let token_url = format!("{}/token", server.base);
        attempt.exchange(&agent(true), &token_url, callback)
    }

    fn redirect(scheme: &str, query: &str) -> String {
        format!("{scheme}:/oauth2redirect?{query}")
    }

    #[test]
    fn the_google_page_asks_for_the_files_leaf_creates_and_proves_the_code() {
        let (address, query) =
            page(&attempt(OAuthProvider::GoogleDrive, GOOGLE_SCHEME).authorization_url());

        assert_eq!(address, "https://accounts.google.com/o/oauth2/v2/auth");
        assert_eq!(query["scope"], "https://www.googleapis.com/auth/drive.file");
        assert_eq!(query["client_id"], CLIENT);
        assert_eq!(
            query["redirect_uri"],
            "com.googleusercontent.apps.123-abc:/oauth2redirect"
        );
        assert_eq!(query["response_type"], "code");
        assert_eq!(query["code_challenge"], CHALLENGE);
        assert_eq!(query["code_challenge_method"], "S256");
        assert_eq!(query["state"], STATE);
        assert_eq!(query["access_type"], "offline");
        assert_eq!(query["prompt"], "consent");
    }

    #[test]
    fn the_microsoft_page_is_for_personal_accounts_and_asks_for_the_app_folder() {
        let (address, query) =
            page(&attempt(OAuthProvider::OneDrive, ONEDRIVE_SCHEME).authorization_url());

        assert_eq!(
            address,
            "https://login.microsoftonline.com/consumers/oauth2/v2.0/authorize"
        );
        assert_eq!(query["scope"], "Files.ReadWrite.AppFolder offline_access");
        assert_eq!(query["redirect_uri"], "msauth.com.timhilt.leaf://auth");
        assert_eq!(query["response_type"], "code");
        assert_eq!(query["code_challenge"], CHALLENGE);
        assert_eq!(query["code_challenge_method"], "S256");
        assert_eq!(query["prompt"], "select_account");
    }

    #[test]
    fn every_attempt_has_its_own_verifier_and_state() {
        let first = SignIn::new(OAuthProvider::GoogleDrive, CLIENT, GOOGLE_SCHEME);
        let second = SignIn::new(OAuthProvider::GoogleDrive, CLIENT, GOOGLE_SCHEME);

        assert_ne!(first.authorization_url(), second.authorization_url());
        assert_eq!(first.verifier.len(), 43);
        assert_ne!(first.verifier, second.verifier);
    }

    #[test]
    fn the_redirect_gives_the_code_of_its_own_attempt() {
        let sign_in = attempt(OAuthProvider::GoogleDrive, GOOGLE_SCHEME);
        let code = |query: &str| sign_in.code(&redirect(GOOGLE_SCHEME, query));

        assert_eq!(code("state=xyz&code=4%2F0Abc"), Ok("4/0Abc".to_owned()));
        assert_eq!(
            code("code=4%2F0Abc&state=xyz#ignored"),
            Ok("4/0Abc".to_owned())
        );
        assert_eq!(
            code("state=other&code=4%2F0Abc"),
            Err(OAuthError::AccessDenied)
        );
        assert_eq!(code("state=xyz"), Err(OAuthError::AccessDenied));
        assert_eq!(code("code=4%2F0Abc"), Err(OAuthError::AccessDenied));
        assert_eq!(sign_in.code(GOOGLE_SCHEME), Err(OAuthError::AccessDenied));
    }

    #[test]
    fn declining_on_the_consent_page_cancels_and_another_error_is_refused() {
        let sign_in = attempt(OAuthProvider::OneDrive, ONEDRIVE_SCHEME);
        let code = |query: &str| sign_in.code(&redirect(ONEDRIVE_SCHEME, query));

        assert_eq!(
            code("state=xyz&error=access_denied"),
            Err(OAuthError::Cancelled)
        );
        assert_eq!(
            code("state=xyz&error=server_error"),
            Err(OAuthError::AccessDenied)
        );
    }

    #[test]
    fn a_consent_must_grant_the_files_leaf_creates() {
        let google = attempt(OAuthProvider::GoogleDrive, GOOGLE_SCHEME);
        assert!(google.grants("https://www.googleapis.com/auth/drive.file"));
        assert!(google.grants("openid https://www.googleapis.com/auth/DRIVE.FILE email"));
        assert!(!google.grants("openid"));
        assert!(!google.grants("https://www.googleapis.com/auth/drive"));

        let microsoft = attempt(OAuthProvider::OneDrive, ONEDRIVE_SCHEME);
        assert!(microsoft.grants("Files.ReadWrite.AppFolder User.Read"));
        assert!(microsoft.grants("https://graph.microsoft.com/Files.ReadWrite.AppFolder"));
        assert!(!microsoft.grants("User.Read"));
        assert!(!microsoft.grants("NotFiles.ReadWrite.AppFolder"));
    }

    #[test]
    fn the_code_is_exchanged_at_the_token_endpoint_for_a_refresh_token() {
        let sign_in = attempt(OAuthProvider::GoogleDrive, GOOGLE_SCHEME);
        let callback = redirect(GOOGLE_SCHEME, "state=xyz&code=4%2F0Abc");
        let consent = consent(
            &sign_in,
            "https://www.googleapis.com/auth/drive.file",
            Some("refresh-1"),
        );

        assert_eq!(
            exchange_at_fake(&sign_in, consent, &callback),
            Ok("refresh-1".to_owned())
        );
    }

    #[test]
    fn a_qualified_scope_of_the_app_folder_grants_the_files() {
        let sign_in = attempt(OAuthProvider::OneDrive, ONEDRIVE_SCHEME);
        let callback = redirect(ONEDRIVE_SCHEME, "state=xyz&code=4%2F0Abc");
        let scope = "https://graph.microsoft.com/Files.ReadWrite.AppFolder openid";
        let consent = consent(&sign_in, scope, Some("refresh-1"));

        assert_eq!(
            exchange_at_fake(&sign_in, consent, &callback),
            Ok("refresh-1".to_owned())
        );
    }

    #[test]
    fn a_consent_without_the_files_is_missing_permission() {
        let sign_in = attempt(OAuthProvider::GoogleDrive, GOOGLE_SCHEME);
        let callback = redirect(GOOGLE_SCHEME, "state=xyz&code=4%2F0Abc");
        let consent = consent(&sign_in, "openid", Some("refresh-1"));

        assert_eq!(
            exchange_at_fake(&sign_in, consent, &callback),
            Err(OAuthError::MissingPermission)
        );
    }

    #[test]
    fn a_token_response_without_a_refresh_token_is_access_denied() {
        let sign_in = attempt(OAuthProvider::GoogleDrive, GOOGLE_SCHEME);
        let callback = redirect(GOOGLE_SCHEME, "state=xyz&code=4%2F0Abc");
        let consent = consent(&sign_in, "https://www.googleapis.com/auth/drive.file", None);

        assert_eq!(
            exchange_at_fake(&sign_in, consent, &callback),
            Err(OAuthError::AccessDenied)
        );
    }

    #[test]
    fn a_code_the_provider_refuses_is_access_denied() {
        let sign_in = attempt(OAuthProvider::GoogleDrive, GOOGLE_SCHEME);
        let callback = redirect(GOOGLE_SCHEME, "state=xyz&code=4%2F0Abc");
        // The exchange has to prove the verifier of this attempt, not another.
        let mut consent = consent(
            &sign_in,
            "https://www.googleapis.com/auth/drive.file",
            Some("refresh-1"),
        );
        consent.verifier = "another-verifier".to_owned();

        assert_eq!(
            exchange_at_fake(&sign_in, consent, &callback),
            Err(OAuthError::AccessDenied)
        );
    }

    #[test]
    fn no_answer_from_the_token_endpoint_is_unreachable() {
        let sign_in = attempt(OAuthProvider::GoogleDrive, GOOGLE_SCHEME);
        let callback = redirect(GOOGLE_SCHEME, "state=xyz&code=4%2F0Abc");

        assert_eq!(
            sign_in.exchange(&agent(true), "http://127.0.0.1:1/token", &callback),
            Err(OAuthError::Unreachable)
        );
    }

    #[test]
    fn declining_is_cancelled_without_contacting_the_provider() {
        let sign_in = attempt(OAuthProvider::OneDrive, ONEDRIVE_SCHEME);
        let callback = redirect(ONEDRIVE_SCHEME, "state=xyz&error=access_denied");

        assert_eq!(sign_in.refresh_token(&callback), Err(OAuthError::Cancelled));
    }
}
