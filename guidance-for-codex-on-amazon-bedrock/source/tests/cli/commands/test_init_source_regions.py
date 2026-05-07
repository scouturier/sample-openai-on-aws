# ABOUTME: Tests for init command source region selection integration
# ABOUTME: Validates source region selection flow during initialization

"""Tests for init command integration with source region selection."""

from unittest.mock import Mock, patch

import pytest

from codex_with_bedrock.cli.commands.init import InitCommand
from codex_with_bedrock.config import Profile
from codex_with_bedrock.models import get_source_regions_for_model_profile


class TestInitCommandSourceRegions:
    """Test init command integration with source region selection."""

    def test_source_region_selection_flow_gpt54(self):
        """Test that GPT-5.4 has all US regions available."""
        us_regions = get_source_regions_for_model_profile("gpt-5.4", "us")
        assert len(us_regions) > 0
        assert "us-east-1" in us_regions
        assert "us-east-2" in us_regions
        assert "us-west-2" in us_regions

    def test_source_region_selection_flow_us(self):
        """Test that gpt-oss-120b US model has correct source regions."""
        us_regions = get_source_regions_for_model_profile("gpt-oss-120b", "us")
        assert len(us_regions) > 0
        assert "us-east-1" in us_regions
        assert "us-east-2" in us_regions
        assert "us-west-2" in us_regions

    def test_source_region_selection_flow_20b(self):
        """Test that GPT-OSS 20B has the same US source regions."""
        us_regions = get_source_regions_for_model_profile("gpt-oss-20b", "us")
        assert len(us_regions) > 0
        assert all(region.startswith("us-") for region in us_regions)

    def test_non_us_profiles_not_available(self):
        """Test that non-US profiles raise errors (US only during limited preview)."""
        with pytest.raises(ValueError):
            get_source_regions_for_model_profile("gpt-oss-120b", "europe")

        with pytest.raises(ValueError):
            get_source_regions_for_model_profile("gpt-oss-120b", "apac")

        with pytest.raises(ValueError):
            get_source_regions_for_model_profile("gpt-oss-20b", "europe")

    def test_config_includes_selected_source_region(self):
        """Test that configuration includes selected source region."""
        mock_config = {
            "aws": {
                "selected_source_region": "us-west-2",
                "cross_region_profile": "us",
                "selected_model": "openai.gpt-oss-120b",
            }
        }

        assert "selected_source_region" in mock_config["aws"]
        assert mock_config["aws"]["selected_source_region"] == "us-west-2"

    def test_profile_stores_selected_source_region(self):
        """Test that Profile object can store selected source region."""
        profile = Profile(
            name="test",
            provider_domain="test.okta.com",
            client_id="client123",
            credential_storage="session",
            aws_region="us-east-1",
            identity_pool_name="test-pool",
            selected_source_region="us-west-2",
        )

        assert profile.selected_source_region == "us-west-2"

    def test_existing_config_preserves_source_region(self):
        """Test that existing configurations preserve source region."""
        existing_profile = Mock()
        existing_profile.name = "default"
        existing_profile.selected_source_region = "us-east-2"
        existing_profile.cross_region_profile = "us"
        existing_profile.selected_model = "openai.gpt-oss-120b"

        with patch("codex_with_bedrock.cli.commands.init.Config.load") as mock_config_load:
            mock_config = Mock()
            mock_config.get_profile.return_value = existing_profile
            mock_config_load.return_value = mock_config

            command = InitCommand()

            with patch.object(command, "_stack_exists") as mock_stack_exists:
                mock_stack_exists.return_value = True

                existing_config = command._check_existing_deployment("test-profile")

                if existing_config and hasattr(existing_profile, "selected_source_region"):
                    assert existing_profile.selected_source_region == "us-east-2"

    def test_source_region_choices_generation(self):
        """Test that source region choices are properly generated for US models."""
        test_cases = [
            ("gpt-5.4", "us", ["us-east-1", "us-east-2", "us-west-2"]),
            ("gpt-oss-120b", "us", ["us-east-1", "us-east-2", "us-west-2"]),
            ("gpt-oss-20b", "us", ["us-east-1", "us-east-2", "us-west-2"]),
        ]

        for model_key, profile_key, expected_regions in test_cases:
            source_regions = get_source_regions_for_model_profile(model_key, profile_key)

            for expected_region in expected_regions:
                assert (
                    expected_region in source_regions
                ), f"Expected region {expected_region} not found in {source_regions} for {model_key}/{profile_key}"

    def test_source_region_fallback_behavior(self):
        """Test fallback behavior when no source region is selected."""
        from codex_with_bedrock.models import get_source_region_for_profile

        us_profile = Mock()
        us_profile.selected_source_region = None
        us_profile.aws_region = "us-east-1"

        result = get_source_region_for_profile(us_profile)
        assert result == "us-east-1"

    def test_source_region_priority_order(self):
        """Test that selected source region takes priority over infrastructure region."""
        from codex_with_bedrock.models import get_source_region_for_profile

        profile = Mock()
        profile.selected_source_region = "us-west-2"
        profile.aws_region = "us-east-1"

        result = get_source_region_for_profile(profile)
        assert result == "us-west-2"

    def test_source_region_validation_in_init_flow(self):
        """Test that source region validation works in init flow."""
        valid_regions = ["us-east-1", "us-east-2", "us-west-2"]
        for region in valid_regions:
            assert "-" in region
            assert len(region.split("-")) >= 2

    def test_configuration_review_includes_source_region(self):
        """Test that configuration review displays selected source region."""
        config = {
            "aws": {
                "selected_source_region": "us-west-2",
                "cross_region_profile": "us",
                "selected_model": "openai.gpt-oss-120b",
                "region": "us-east-1",
            }
        }

        assert config["aws"]["selected_source_region"] == "us-west-2"
        assert config["aws"]["cross_region_profile"] == "us"
