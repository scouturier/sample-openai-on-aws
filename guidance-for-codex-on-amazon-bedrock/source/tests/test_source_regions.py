# ABOUTME: Tests for source region selection functionality
# ABOUTME: Validates user-selected source regions and fallback logic

"""Tests for source region selection functionality."""

from unittest.mock import Mock

import pytest

from codex_with_bedrock.models import (
    BEDROCK_MODELS,
    get_source_region_for_profile,
    get_source_regions_for_model_profile,
)


class TestSourceRegionFunctionality:
    """Test source region selection and configuration."""

    def test_source_regions_available_for_models(self):
        """Test that source regions are available for all model/profile combinations."""
        for model_key, model_config in BEDROCK_MODELS.items():
            for profile_key, profile_config in model_config["profiles"].items():
                source_regions = profile_config["source_regions"]

                assert isinstance(source_regions, list)
                assert len(source_regions) > 0, f"No source regions for {model_key}/{profile_key}"

                for region in source_regions:
                    assert isinstance(region, str)
                    assert len(region) > 0
                    assert "-" in region and len(region.split("-")) >= 2

    def test_get_source_regions_for_us_models(self):
        """Test getting source regions for US models."""
        for model_key in ["gpt-5.4", "gpt-oss-120b", "gpt-oss-20b"]:
            us_regions = get_source_regions_for_model_profile(model_key, "us")
            assert isinstance(us_regions, list)
            assert len(us_regions) > 0
            assert "us-east-1" in us_regions
            assert "us-east-2" in us_regions
            assert "us-west-2" in us_regions

    def test_get_source_region_for_profile_with_selected_region(self):
        """Test source region selection when user has selected a specific region."""
        profile = Mock()
        profile.selected_source_region = "us-east-2"
        profile.aws_region = "us-east-1"

        result = get_source_region_for_profile(profile)
        assert result == "us-east-2"

    def test_get_source_region_for_profile_fallback_to_aws_region(self):
        """Test source region fallback to infrastructure region."""
        profile = Mock()
        profile.selected_source_region = None
        profile.aws_region = "us-west-2"

        result = get_source_region_for_profile(profile)
        assert result == "us-west-2"

    def test_get_source_region_for_profile_no_attributes(self):
        """Test source region when profile has minimal attributes."""
        profile = Mock()
        profile.selected_source_region = None
        profile.aws_region = "us-east-1"

        result = get_source_region_for_profile(profile)
        assert result == "us-east-1"

    def test_source_region_regional_consistency(self):
        """Test that all source regions are US regions."""
        for model_key in BEDROCK_MODELS.keys():
            source_regions = get_source_regions_for_model_profile(model_key, "us")
            for region in source_regions:
                assert region.startswith("us-"), (
                    f"Region {region} doesn't start with us- for {model_key}/us"
                )

    def test_source_region_invalid_model_profile_combinations(self):
        """Test that invalid model/profile combinations raise appropriate errors."""
        invalid_combinations = [
            ("gpt-oss-120b", "europe"),
            ("gpt-oss-120b", "apac"),
            ("gpt-oss-20b", "europe"),
            ("invalid-model", "us"),
            ("gpt-oss-120b", "invalid-profile"),
        ]

        for model_key, profile_key in invalid_combinations:
            with pytest.raises(ValueError):
                get_source_regions_for_model_profile(model_key, profile_key)

    def test_source_region_profile_with_getattr_fallback(self):
        """Test source region selection with getattr-style profile access."""
        profile = Mock()

        del profile.selected_source_region
        profile.aws_region = "us-east-1"

        result = get_source_region_for_profile(profile)
        assert result == "us-east-1"

    def test_all_models_have_source_regions(self):
        """Test that all models in BEDROCK_MODELS have source regions defined."""
        for model_key, model_config in BEDROCK_MODELS.items():
            for profile_key, profile_config in model_config["profiles"].items():
                assert (
                    "source_regions" in profile_config
                ), f"Model {model_key} profile {profile_key} missing source_regions"

                source_regions = profile_config["source_regions"]
                assert len(source_regions) > 0, f"Model {model_key} profile {profile_key} has empty source_regions"

    def test_source_regions_are_us_only(self):
        """Test that source regions only contain US regions (limited preview)."""
        valid_us_regions = {"us-east-1", "us-east-2", "us-west-2"}

        for model_key, model_config in BEDROCK_MODELS.items():
            for profile_key, profile_config in model_config["profiles"].items():
                source_regions = profile_config["source_regions"]
                for region in source_regions:
                    assert region in valid_us_regions, (
                        f"Unexpected non-US region {region} for {model_key}/{profile_key}. "
                        f"Only US regions are supported during limited preview."
                    )
