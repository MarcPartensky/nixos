//! Minimal OpenAI-compatible chat client.
//!
//! The engine does not care which model answers: the free pool on the laptop
//! (model alias `free-pool`), a local llama-swap, or a paid provider. Only the
//! base URL and the model name change.

use crate::config::Config;
use crate::R;
use serde_json::{json, Value};

#[derive(Clone)]
pub struct Llm {
    client: reqwest::Client,
    url: String,
    model: String,
    key: Option<String>,
    zdr: bool,
}

impl Llm {
    pub fn new(cfg: &Config) -> Self {
        let key = match (&cfg.llm_key, &cfg.llm_key_file) {
            (Some(key), _) => Some(key.clone()),
            (None, Some(path)) => std::fs::read_to_string(path)
                .ok()
                .map(|text| text.trim().to_string())
                .filter(|text| !text.is_empty()),
            _ => None,
        };
        Llm {
            client: reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(600))
                .build()
                .unwrap_or_default(),
            url: cfg.api_url(),
            model: cfg.llm_model.clone(),
            key,
            zdr: cfg.llm_zdr,
        }
    }

    pub fn model(&self) -> &str {
        &self.model
    }

    /// Ask for prose. Returns (text, model that actually answered).
    pub async fn chat(&self, system: &str, user: &str, max_tokens: u32) -> R<(String, String)> {
        self.send(system, user, max_tokens, false).await
    }

    /// Ask for strict JSON. Returns the parsed value and the answering model.
    pub async fn chat_json(
        &self,
        system: &str,
        user: &str,
        max_tokens: u32,
    ) -> R<(Value, String)> {
        let (text, model) = self.send(system, user, max_tokens, true).await?;
        match parse_json(&text) {
            Ok(v) => Ok((v, model)),
            Err(_) => {
                // Some free providers ignore response_format. One retry without
                // it, then give up: a wrong answer is worse than no answer.
                let (text, model) = self.send(system, user, max_tokens, false).await?;
                Ok((parse_json(&text)?, model))
            }
        }
    }

    async fn send(
        &self,
        system: &str,
        user: &str,
        max_tokens: u32,
        json_mode: bool,
    ) -> R<(String, String)> {
        let mut body = json!({
            "model": self.model,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
            "temperature": 0.2,
            "max_tokens": max_tokens,
        });
        if json_mode {
            body["response_format"] = json!({"type": "json_object"});
        }
        if self.zdr {
            body["provider"] = json!({"zdr": true});
        }
        let mut req = self.client.post(&self.url).json(&body);
        if let Some(key) = &self.key {
            req = req.bearer_auth(key);
        }
        let resp = req.send().await?;
        let status = resp.status();
        let text = resp.text().await?;
        if !status.is_success() {
            let head: String = text.chars().take(300).collect();
            return Err(format!("llm HTTP {}: {}", status.as_u16(), head).into());
        }
        let value: Value = serde_json::from_str(&text)?;
        let content = value["choices"][0]["message"]["content"]
            .as_str()
            .unwrap_or_default()
            .to_string();
        if content.trim().is_empty() {
            return Err("llm returned an empty answer".into());
        }
        let model = value["model"].as_str().unwrap_or(&self.model).to_string();
        Ok((content, model))
    }
}

/// Pull the first JSON object out of an answer that may carry prose or fences.
pub fn parse_json(text: &str) -> R<Value> {
    let cleaned = text
        .trim()
        .trim_start_matches("```json")
        .trim_start_matches("```")
        .trim_end_matches("```")
        .trim();
    if let Ok(v) = serde_json::from_str::<Value>(cleaned) {
        return Ok(v);
    }
    let start = cleaned.find(['{', '[']).ok_or("no JSON in the answer")?;
    let end = cleaned
        .rfind(['}', ']'])
        .ok_or("unterminated JSON in the answer")?;
    Ok(serde_json::from_str(&cleaned[start..=end])?)
}
