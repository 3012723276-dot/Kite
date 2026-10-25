//! Stable, privacy-safe error classification shared by desktop, Android and Web.
//!
//! NetEase occasionally returns challenge/rate-limit responses that are not
//! client regressions.  Keeping the classification in the shared core lets
//! each UI show the same state without exposing cookies or response bodies.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorClass {
    AuthRequired,
    QrExpired,
    RateLimited,
    RegionRestricted,
    Unplayable,
    Network,
    Decoding,
    ExternalChallenge,
    Unknown,
}

#[must_use]
pub fn classify_business_code(code: i64, message: &str) -> ErrorClass {
    let message = message.to_ascii_lowercase();
    match code {
        301 | 401 | 403 => ErrorClass::AuthRequired,
        800 => ErrorClass::QrExpired,
        -460 | -462 | 429 => ErrorClass::ExternalChallenge,
        2005 | 2201 | 2202 => ErrorClass::RegionRestricted,
        404 | 405 | 1060 => ErrorClass::Unplayable,
        _ if message.contains("地区") || message.contains("region") => {
            ErrorClass::RegionRestricted
        }
        _ if message.contains("验证") || message.contains("captcha") => {
            ErrorClass::ExternalChallenge
        }
        _ => ErrorClass::Unknown,
    }
}

#[must_use]
pub fn classify_http_status(status: u16) -> ErrorClass {
    match status {
        401 | 403 => ErrorClass::AuthRequired,
        408 | 425 | 429 => ErrorClass::ExternalChallenge,
        500..=599 => ErrorClass::Network,
        _ => ErrorClass::Unknown,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn challenge_codes_are_not_reported_as_code_regressions() {
        assert_eq!(
            classify_business_code(-462, "请完成验证操作"),
            ErrorClass::ExternalChallenge
        );
        assert_eq!(
            classify_business_code(-460, "rate limit"),
            ErrorClass::ExternalChallenge
        );
        assert_eq!(classify_http_status(429), ErrorClass::ExternalChallenge);
        assert_eq!(classify_business_code(500, "server"), ErrorClass::Unknown);
    }

    #[test]
    fn auth_and_region_errors_are_stable() {
        assert_eq!(
            classify_business_code(301, "需要登录"),
            ErrorClass::AuthRequired
        );
        assert_eq!(
            classify_business_code(2005, "地区限制"),
            ErrorClass::RegionRestricted
        );
    }
}
