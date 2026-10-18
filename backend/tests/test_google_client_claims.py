import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from app.core.identity import validate_google_client_claims  # noqa: E402


class GoogleClientClaimsTest(unittest.TestCase):
    def test_native_authorized_party_is_separate_from_web_audience(self):
        validate_google_client_claims(
            {"aud": "web-client.apps.googleusercontent.com", "azp": "android-client.apps.googleusercontent.com"},
            allowed_audiences={"web-client.apps.googleusercontent.com"},
            allowed_authorized_parties={"android-client.apps.googleusercontent.com"},
        )

    def test_unapproved_audience_is_rejected_even_if_azp_is_allowed(self):
        with self.assertRaisesRegex(PermissionError, "outro aplicativo"):
            validate_google_client_claims(
                {"aud": "unknown.apps.googleusercontent.com", "azp": "android-client.apps.googleusercontent.com"},
                allowed_audiences={"web-client.apps.googleusercontent.com"},
                allowed_authorized_parties={"android-client.apps.googleusercontent.com"},
            )

    def test_unapproved_native_authorized_party_is_rejected(self):
        with self.assertRaisesRegex(PermissionError, "GOOGLE_OAUTH_AUTHORIZED_PARTY_IDS"):
            validate_google_client_claims(
                {"aud": "web-client.apps.googleusercontent.com", "azp": "unknown-android.apps.googleusercontent.com"},
                allowed_audiences={"web-client.apps.googleusercontent.com"},
                allowed_authorized_parties=set(),
            )


if __name__ == "__main__":
    unittest.main()
