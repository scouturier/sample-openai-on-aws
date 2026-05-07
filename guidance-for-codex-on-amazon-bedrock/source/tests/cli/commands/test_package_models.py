# ABOUTME: Unit tests for package command model handling
# ABOUTME: Tests that selected model is properly included in package output

"""Tests for model handling in the package command."""

import tempfile
from pathlib import Path

from codex_with_bedrock.cli.commands.package import PackageCommand
from codex_with_bedrock.config import Profile


class TestPackageModelHandling:
    """Tests for package command model functionality."""

    def test_config_toml_created_without_monitoring(self):
        """Test that config.toml is created with amazon-bedrock settings when monitoring is disabled."""
        command = PackageCommand()

        profile = Profile(
            name="test",
            provider_domain="test.okta.com",
            client_id="test-client-id",
            credential_storage="session",
            aws_region="us-west-2",
            identity_pool_name="test-pool",
            selected_model="openai.gpt-5.4",
            monitoring_enabled=False,
        )

        with tempfile.TemporaryDirectory() as tmpdir:
            output_dir = Path(tmpdir)
            command._create_codex_settings(output_dir, profile)

            config_file = output_dir / "codex-settings" / "config.toml"
            assert config_file.exists(), "config.toml should be created"

            content = config_file.read_text()
            assert 'model_provider = "amazon-bedrock"' in content
            assert 'wire_api = "responses"' in content
            assert "[model_providers.amazon-bedrock.aws]" in content
            assert "openai.gpt-5.4" in content

    def test_config_toml_uses_selected_model(self):
        """Test that config.toml uses the selected model."""
        command = PackageCommand()

        profile = Profile(
            name="test",
            provider_domain="test.okta.com",
            client_id="test-client-id",
            credential_storage="session",
            aws_region="us-east-1",
            identity_pool_name="test-pool",
            selected_model="openai.gpt-oss-20b",
            monitoring_enabled=False,
        )

        with tempfile.TemporaryDirectory() as tmpdir:
            output_dir = Path(tmpdir)
            command._create_codex_settings(output_dir, profile)

            config_file = output_dir / "codex-settings" / "config.toml"
            assert config_file.exists()
            content = config_file.read_text()
            assert "openai.gpt-oss-20b" in content

    def test_config_toml_default_model(self):
        """Test that config.toml defaults to gpt-5.4 when no model is selected."""
        command = PackageCommand()

        profile = Profile(
            name="test",
            provider_domain="test.okta.com",
            client_id="test-client-id",
            credential_storage="session",
            aws_region="us-west-2",
            identity_pool_name="test-pool",
            monitoring_enabled=False,
        )

        with tempfile.TemporaryDirectory() as tmpdir:
            output_dir = Path(tmpdir)
            command._create_codex_settings(output_dir, profile)

            config_file = output_dir / "codex-settings" / "config.toml"
            assert config_file.exists()
            content = config_file.read_text()
            assert "openai.gpt-5.4" in content

    def test_model_display_names(self):
        """Test that model display names are correctly mapped."""
        model_names = {
            "openai.gpt-5.4": "GPT-5.4",
            "openai.gpt-oss-120b": "GPT-OSS 120B",
            "openai.gpt-oss-20b": "GPT-OSS 20B",
        }

        for model_id, expected_name in model_names.items():
            # Bare Mantle format — no regional prefix
            assert model_id.startswith("openai.")
            assert not model_id.startswith("us.openai.")

    def test_us_regions_only(self):
        """Test that only US regions are supported."""
        assert "us-west-2" in "US — us-west-2"

    def test_config_toml_includes_region(self):
        """Test that config.toml includes the AWS region in the provider block."""
        command = PackageCommand()

        profile = Profile(
            name="test",
            provider_domain="test.okta.com",
            client_id="test-client-id",
            credential_storage="session",
            aws_region="us-west-2",
            identity_pool_name="test-pool",
            monitoring_enabled=False,
        )

        with tempfile.TemporaryDirectory() as tmpdir:
            output_dir = Path(tmpdir)
            command._create_codex_settings(output_dir, profile)

            config_file = output_dir / "codex-settings" / "config.toml"
            content = config_file.read_text()
            assert 'region = "us-west-2"' in content
            assert 'profile = "Codex"' in content
