//! Connected clients hold only an HTTPS origin and an in-memory session cookie.
//! Every path is fixed by this module; redirects never receive credentials.
use reqwest::{Client, Url};
use sbco_contracts::{Login, TrainingContext};
use sbco_domain::Actor;
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use serde_json::{Value, json};
use std::{path::PathBuf, time::Duration};
use tokio::sync::RwLock;

#[derive(Clone, Serialize)]
pub struct ConnectionStatus {
    pub mode: &'static str,
    pub server_url: Option<String>,
    pub configured: bool,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Configuration {
    server_url: String,
}
struct Endpoint {
    origin: Url,
    client: Client,
}
pub struct Remote {
    path: PathBuf,
    endpoint: RwLock<Option<Endpoint>>,
}

fn validate_origin(value: &str, allow_local_http: bool) -> Result<Url, String> {
    let url = Url::parse(value.trim()).map_err(|_| {
        "Enter a complete HTTPS server address, such as https://sbco.example.org".to_string()
    })?;
    if url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
        || url.path() != "/"
    {
        return Err("Enter only the server's HTTPS address, without a path, account details, query or fragment".into());
    }
    let local = matches!(url.host_str(), Some("localhost" | "127.0.0.1" | "[::1]"));
    if url.scheme() != "https" && !(allow_local_http && local && url.scheme() == "http") {
        return Err("A secure HTTPS server address is required".into());
    }
    Ok(url)
}
fn allow_local_http() -> bool {
    cfg!(debug_assertions) && std::env::var("SBCO_CONNECTED_ALLOW_LOCAL_HTTP").as_deref() == Ok("1")
}
fn endpoint(origin: Url) -> Result<Endpoint, String> {
    let client = Client::builder()
        .cookie_store(true)
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(90))
        .user_agent(concat!("SBCO-Desktop/", env!("CARGO_PKG_VERSION")))
        .build()
        .map_err(|_| "Unable to initialize the secure connection".to_string())?;
    Ok(Endpoint { origin, client })
}
async fn bytes(
    endpoint: &Endpoint,
    path: &str,
    body: Option<Value>,
    training: Option<&TrainingContext>,
) -> Result<Vec<u8>, String> {
    let url = endpoint
        .origin
        .join(path)
        .map_err(|_| "Invalid server endpoint".to_string())?;
    let mut request = if let Some(body) = body {
        endpoint.client.post(url).json(&body)
    } else {
        endpoint.client.get(url)
    };
    request = request.header("X-SBCO-Request", "1");
    if let Some(context) = training {
        request = request.header(
            "X-SBCO-Training",
            serde_json::to_string(context).map_err(|_| "Invalid training selection".to_string())?,
        );
    }
    let mut response = request.send().await.map_err(|error| {
        if error.is_timeout() { "The server took too long to respond. Check the connection and retry." }
        else { "Cannot securely reach the server. Check its address, network connection and trusted HTTPS certificate." }.to_string()
    })?;
    let status = response.status();
    if status.is_redirection() {
        return Err(
            "The server redirected this request. Enter its final HTTPS address instead.".into(),
        );
    }
    let mut content = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| "The server response was interrupted".to_string())?
    {
        if content.len() + chunk.len() > 64_000_000 {
            return Err("The server response is too large".into());
        }
        content.extend_from_slice(&chunk);
    }
    if !status.is_success() {
        if status.as_u16() == 401 {
            return Err("Sign in to continue".into());
        }
        return Err(serde_json::from_slice::<Value>(&content)
            .ok()
            .and_then(|v| v.get("error").and_then(Value::as_str).map(str::to_owned))
            .filter(|message| message.len() <= 1000)
            .unwrap_or_else(|| {
                format!(
                    "The server could not complete this request ({})",
                    status.as_u16()
                )
            }));
    }
    Ok(content)
}
async fn verify_server(candidate: &Endpoint) -> Result<(), String> {
    let metadata = bytes(candidate, "/api/v1/server-info", None, None).await?;
    let metadata: Value = serde_json::from_slice(&metadata)
        .map_err(|_| "This address did not return an SBCO server".to_string())?;
    if metadata["application"] != "SBCO"
        || metadata["api_version"] != 1
        || !metadata["capabilities"]
            .as_array()
            .is_some_and(|items| items.iter().any(|item| item == "training"))
    {
        return Err("This server is not compatible with this SBCO client. Ask your administrator to update the server or client.".into());
    }
    Ok(())
}
impl Remote {
    pub fn load(root: PathBuf) -> Result<Self, String> {
        std::fs::create_dir_all(&root)
            .map_err(|_| "Cannot create the connection settings folder".to_string())?;
        let path = root.join("server-connection.json");
        let endpoint = std::fs::read(&path)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<Configuration>(&bytes).ok())
            .and_then(|config| validate_origin(&config.server_url, allow_local_http()).ok())
            .map(endpoint)
            .transpose()?;
        Ok(Self {
            path,
            endpoint: RwLock::new(endpoint),
        })
    }
    pub async fn status(&self) -> ConnectionStatus {
        let endpoint = self.endpoint.read().await;
        ConnectionStatus {
            mode: "connected",
            server_url: endpoint
                .as_ref()
                .map(|e| e.origin.as_str().trim_end_matches('/').to_string()),
            configured: endpoint.is_some(),
        }
    }
    pub async fn configure(&self, address: &str) -> Result<ConnectionStatus, String> {
        let candidate = endpoint(validate_origin(address, allow_local_http())?)?;
        verify_server(&candidate).await?;
        let config = serde_json::to_vec(&Configuration {
            server_url: candidate.origin.to_string(),
        })
        .map_err(|_| "Unable to save server address".to_string())?;
        let mut current = self.endpoint.write().await;
        let temporary = self.path.with_extension("tmp");
        std::fs::write(&temporary, config)
            .and_then(|_| std::fs::rename(&temporary, &self.path))
            .map_err(|_| "Unable to save server address".to_string())?;
        *current = Some(candidate); // New cookie jar: never carry a session to another server.
        drop(current);
        Ok(self.status().await)
    }
    pub async fn json<T: DeserializeOwned>(
        &self,
        path: &str,
        body: Option<Value>,
        training: Option<&TrainingContext>,
    ) -> Result<T, String> {
        let endpoint = self.endpoint.read().await;
        let endpoint = endpoint
            .as_ref()
            .ok_or("Connect to your SBCO server first")?;
        let response = bytes(endpoint, path, body, training).await?;
        serde_json::from_slice(&response)
            .map_err(|_| "The server returned an unexpected response".into())
    }
    pub async fn download(
        &self,
        path: &str,
        body: Option<Value>,
        training: Option<&TrainingContext>,
    ) -> Result<Vec<u8>, String> {
        let endpoint = self.endpoint.read().await;
        bytes(
            endpoint
                .as_ref()
                .ok_or("Connect to your SBCO server first")?,
            path,
            body,
            training,
        )
        .await
    }
    pub async fn login(&self, credentials: Login) -> Result<Actor, String> {
        let mut current = self.endpoint.write().await;
        let origin = current
            .as_ref()
            .ok_or("Connect to your SBCO server first")?
            .origin
            .clone();
        *current = Some(endpoint(origin)?);
        let candidate = current.as_ref().expect("Endpoint was just initialized");
        verify_server(candidate).await?;
        let response = bytes(candidate, "/api/v1/login", Some(json!(credentials)), None).await?;
        serde_json::from_slice(&response)
            .map_err(|_| "The server returned an unexpected identity".into())
    }
    pub async fn logout(&self) -> Result<(), String> {
        let mut current = self.endpoint.write().await;
        let Some(previous) = current.as_ref() else {
            return Ok(());
        };
        // Local sign-out must remain usable when the old server is unavailable.
        let _ = tokio::time::timeout(
            Duration::from_secs(3),
            bytes(previous, "/api/v1/logout", Some(json!({})), None),
        )
        .await;
        *current = Some(endpoint(previous.origin.clone())?);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn server_address_is_an_exact_secure_origin() {
        assert!(validate_origin("https://sbco.example.test:8443/", false).is_ok());
        for value in [
            "http://sbco.example.test",
            "https://u:p@sbco.example.test",
            "https://sbco.example.test/api",
            "https://sbco.example.test?token=x",
            "https://sbco.example.test#x",
            "file:///tmp/server",
            "http://localhost",
        ] {
            assert!(validate_origin(value, false).is_err(), "{value}");
        }
        assert!(validate_origin("http://127.0.0.1:8091", true).is_ok());
        assert!(validate_origin("http://localhost.attacker.test", true).is_err());
    }
    async fn mock_server(responses: Vec<String>) -> (Url, tokio::task::JoinHandle<Vec<String>>) {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = Url::parse(&format!("http://{}/", listener.local_addr().unwrap())).unwrap();
        let task = tokio::spawn(async move {
            let mut requests = Vec::new();
            for response in responses {
                let (mut socket, _) = listener.accept().await.unwrap();
                let mut request = Vec::new();
                let mut buffer = [0u8; 4096];
                loop {
                    let count = socket.read(&mut buffer).await.unwrap();
                    assert!(count > 0);
                    request.extend_from_slice(&buffer[..count]);
                    if let Some(end) = request.windows(4).position(|part| part == b"\r\n\r\n") {
                        let headers = String::from_utf8_lossy(&request[..end]).to_lowercase();
                        let length: usize = headers
                            .lines()
                            .find_map(|line| line.strip_prefix("content-length:"))
                            .map(|value| value.trim().parse().unwrap())
                            .unwrap_or(0);
                        if request.len() >= end + 4 + length {
                            break;
                        }
                    }
                }
                requests.push(String::from_utf8(request).unwrap());
                socket.write_all(response.as_bytes()).await.unwrap();
            }
            requests
        });
        (url, task)
    }
    fn response(status: &str, headers: &str, body: &str) -> String {
        format!(
            "HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n{headers}\r\n{body}",
            body.len()
        )
    }
    #[tokio::test]
    async fn session_cookie_workspace_headers_and_logout_stay_in_rust() {
        let identity =
            json!({"id":uuid::Uuid::new_v4(),"name":"Practice owner","role":"Administrator"});
        let (url, server) = mock_server(vec![
            response("200 OK", "", &json!({"application":"SBCO","api_version":1,"capabilities":["training"]}).to_string()),
            response("200 OK", "Set-Cookie: sbco_session=private-test-session; HttpOnly; Path=/; SameSite=Strict\r\n", &identity.to_string()),
            response("200 OK", "", "{\"ok\":true}"),
            response("200 OK", "", "{\"ok\":true}"),
            response("401 Unauthorized", "", "{\"error\":\"expired\"}"),
        ]).await;
        let remote = Remote {
            path: PathBuf::new(),
            endpoint: RwLock::new(Some(endpoint(url).unwrap())),
        };
        remote
            .login(Login {
                email: "example@example.test".into(),
                password: "test-only-password".into(),
            })
            .await
            .unwrap();
        let training = TrainingContext {
            generation: uuid::Uuid::new_v4(),
            role: "Pa".into(),
        };
        let _: Value = remote
            .json(
                "/api/v1/query",
                Some(json!({"kind":"offices"})),
                Some(&training),
            )
            .await
            .unwrap();
        remote.logout().await.unwrap();
        assert_eq!(
            remote
                .json::<Value>("/api/v1/me", None, None)
                .await
                .unwrap_err(),
            "Sign in to continue"
        );
        let requests = server.await.unwrap();
        assert!(!requests[0].to_lowercase().contains("cookie:"));
        let query = requests[2].to_lowercase();
        assert!(query.contains("cookie: sbco_session=private-test-session"));
        assert!(query.contains("x-sbco-request: 1"));
        assert!(query.contains("x-sbco-training:"));
        assert!(query.contains(&training.generation.to_string()));
        assert!(!requests[4].to_lowercase().contains("cookie:"));
    }
    #[tokio::test]
    async fn redirects_and_incompatible_servers_are_rejected() {
        let (url, server) = mock_server(vec![response(
            "302 Found",
            "Location: https://other.example.test/\r\n",
            "",
        )])
        .await;
        assert!(
            bytes(&endpoint(url).unwrap(), "/api/v1/me", None, None)
                .await
                .unwrap_err()
                .contains("redirected")
        );
        assert_eq!(server.await.unwrap().len(), 1);
        let (url, server) = mock_server(vec![response(
            "200 OK",
            "",
            "{\"application\":\"Other\",\"api_version\":1}",
        )])
        .await;
        assert!(
            verify_server(&endpoint(url).unwrap())
                .await
                .unwrap_err()
                .contains("not compatible")
        );
        server.await.unwrap();
    }
    #[tokio::test]
    async fn sign_out_is_bounded_when_server_stops_responding() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = Url::parse(&format!("http://{}/", listener.local_addr().unwrap())).unwrap();
        let server = tokio::spawn(async move {
            let (_socket, _) = listener.accept().await.unwrap();
            tokio::time::sleep(Duration::from_secs(30)).await;
        });
        let remote = Remote {
            path: PathBuf::new(),
            endpoint: RwLock::new(Some(endpoint(url).unwrap())),
        };
        tokio::time::timeout(Duration::from_secs(5), remote.logout())
            .await
            .unwrap()
            .unwrap();
        server.abort();
    }
}
