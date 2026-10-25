//! NetEase Cloud Music request encryption shared by Windows and Android.
//!
//! This module intentionally mirrors the upstream Swift implementation in
//! `Sources/Kumone/Core/API/NeteaseCrypto.swift`. Shared vectors under
//! `contracts/` are compatibility gates for every downstream implementation.

use aes::Aes128;
use base64::{Engine as _, engine::general_purpose::STANDARD as BASE64};
use cbc::Encryptor as CbcEncryptor;
use cipher::{BlockEncryptMut, KeyInit, KeyIvInit, block_padding::Pkcs7};
use ecb::Encryptor as EcbEncryptor;
use md5::{Digest, Md5};
use serde::{Deserialize, Serialize};

// Public NetEase wire-protocol constants, not app credentials. WEAPI_IV is
// intentionally fixed for protocol compatibility and must not be randomized.
const WEAPI_PRESET_KEY: &[u8; 16] = b"0CoJUm6Qyw8W8jud";
const WEAPI_IV: &[u8; 16] = b"0102030405060708";
const WEAPI_SECRET_KEY: &[u8; 16] = b"Kite200901272026";
const WEAPI_ENC_SEC_KEY: &str = concat!(
    "5fea198f30ecdd9e142c8c8a8cd4363b9e5fc21a56145b1514ec03df16af22fb",
    "951f691d65d225c9ea6502fd8c0352956aa9d99bda184424096c74991448b981",
    "0ced9d16a27d9f14fb799a3c03326dad50ad7f6644beb932e23dcfb16ceb5821",
    "05487a24ab4869336d090685cd27660e208bbeb31a197a37561f40e7adc332ca"
);
const EAPI_KEY: &[u8; 16] = b"e82ckenh8dichen8";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WeapiForm {
    pub params: String,
    #[serde(rename = "encSecKey")]
    pub enc_sec_key: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EapiForm {
    pub params: String,
}

/// Encrypt a UTF-8 JSON payload for a `/weapi/...` endpoint.
#[must_use]
pub fn weapi(json_text: &str) -> WeapiForm {
    let first = encrypt_cbc(json_text.as_bytes(), WEAPI_PRESET_KEY, WEAPI_IV);
    let first_base64 = BASE64.encode(first);
    let second = encrypt_cbc(first_base64.as_bytes(), WEAPI_SECRET_KEY, WEAPI_IV);

    WeapiForm {
        params: BASE64.encode(second),
        enc_sec_key: WEAPI_ENC_SEC_KEY.to_owned(),
    }
}

/// Encrypt a UTF-8 JSON payload for an `/eapi/...` endpoint.
#[must_use]
pub fn eapi(api_path: &str, json_text: &str) -> EapiForm {
    let digest_input = format!("nobody{api_path}use{json_text}md5forencrypt");
    let digest = Md5::digest(digest_input.as_bytes());
    let digest_hex = hex::encode(digest);
    let message = format!("{api_path}-36cd479b6b5-{json_text}-36cd479b6b5-{digest_hex}");
    let encrypted = encrypt_ecb(message.as_bytes(), EAPI_KEY);

    EapiForm {
        params: hex::encode_upper(encrypted),
    }
}

fn encrypt_cbc(data: &[u8], key: &[u8; 16], iv: &[u8; 16]) -> Vec<u8> {
    CbcEncryptor::<Aes128>::new_from_slices(key, iv)
        .expect("AES-128 key and IV constants must remain 16 bytes")
        .encrypt_padded_vec_mut::<Pkcs7>(data)
}

fn encrypt_ecb(data: &[u8], key: &[u8; 16]) -> Vec<u8> {
    EcbEncryptor::<Aes128>::new_from_slice(key)
        .expect("AES-128 key constant must remain 16 bytes")
        .encrypt_padded_vec_mut::<Pkcs7>(data)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Debug, serde::Deserialize)]
    struct ContractFile {
        schema_version: u32,
        cases: Vec<ContractCase>,
    }

    #[derive(Debug, serde::Deserialize)]
    struct ContractCase {
        name: String,
        json: String,
        eapi_path: String,
        weapi_params: String,
        weapi_enc_sec_key: String,
        eapi_params: String,
    }

    #[test]
    fn shared_crypto_contract_vectors_match() {
        let fixture: ContractFile =
            serde_json::from_str(include_str!("../../../contracts/crypto-vectors.json"))
                .expect("valid shared crypto contract fixture");
        assert_eq!(fixture.schema_version, 1);
        assert!(!fixture.cases.is_empty());

        for case in fixture.cases {
            let weapi_result = weapi(&case.json);
            assert_eq!(
                weapi_result.params, case.weapi_params,
                "{} weapi",
                case.name
            );
            assert_eq!(
                weapi_result.enc_sec_key, case.weapi_enc_sec_key,
                "{} encSecKey",
                case.name
            );

            let eapi_result = eapi(&case.eapi_path, &case.json);
            assert_eq!(eapi_result.params, case.eapi_params, "{} eapi", case.name);
        }
    }

    #[test]
    fn player_url_vector_remains_protocol_compatible() {
        const SAMPLE_JSON: &str = r#"{"ids":"[347230]","level":"standard"}"#;
        let result = eapi("/api/song/enhance/player/url/v1", SAMPLE_JSON);
        assert_eq!(
            result.params,
            "FA90B329E9614F79E79598F37DC2EDB487F00D1BC4C9B24CD57E6C318B9073569338432CD7D98D1A3626E997A2C53121C461EE0E88D3D1BF3F42E78643807A29B83D00D24CECA2C01F229A64E4D80CBB5EEF4A69DCB79E93C1D2301D38DAC26511D81BB3F926495784500B9A0C9F7DD47E1396F5D6B610C295193B8A1FCBA1AD"
        );
    }
}
