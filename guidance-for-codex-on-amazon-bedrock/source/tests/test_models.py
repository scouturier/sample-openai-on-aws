# ABOUTME: Tests for centralized model configuration system
# ABOUTME: Ensures correct model availability, IDs, regions, and descriptions

"""Tests for the centralized model configuration system."""

import pytest

from codex_with_bedrock.models import (
    BEDROCK_MODELS,
    DEFAULT_REGIONS,
    get_all_model_display_names,
    get_available_profiles_for_model,
    get_default_region_for_profile,
    get_destination_regions_for_model_profile,
    get_model_id_for_profile,
    get_profile_description,
    get_source_regions_for_model_profile,
)


class TestModelConfiguration:
    """Test the centralized model configuration system."""

    def test_default_regions_structure(self):
        """Test that DEFAULT_REGIONS has the expected structure."""
        assert set(DEFAULT_REGIONS.keys()) == {"us"}
        assert DEFAULT_REGIONS["us"] == "us-west-2"

    def test_bedrock_models_structure(self):
        """Test that BEDROCK_MODELS has the expected structure."""
        expected_models = {"gpt-5.4", "gpt-oss-120b", "gpt-oss-20b"}
        assert set(BEDROCK_MODELS.keys()) == expected_models

        for _model_key, model_config in BEDROCK_MODELS.items():
            assert "name" in model_config
            assert "base_model_id" in model_config
            assert "profiles" in model_config
            assert isinstance(model_config["profiles"], dict)
            assert len(model_config["profiles"]) > 0

    def test_model_profiles_structure(self):
        """Test that each model profile has the expected structure."""
        for _model_key, model_config in BEDROCK_MODELS.items():
            for profile_key, profile_config in model_config["profiles"].items():
                assert "model_id" in profile_config
                assert "description" in profile_config
                assert "source_regions" in profile_config
                assert "destination_regions" in profile_config

                assert profile_key == "us", f"Only US profile expected, got: {profile_key}"

                # Bedrock Mantle model IDs use bare format (no regional prefix)
                model_id = profile_config["model_id"]
                assert model_id.startswith("openai."), f"Expected openai. prefix, got: {model_id}"

    def test_get_available_profiles_for_model(self):
        """Test getting available profiles for each model."""
        assert get_available_profiles_for_model("gpt-5.4") == ["us"]
        assert get_available_profiles_for_model("gpt-oss-120b") == ["us"]
        assert get_available_profiles_for_model("gpt-oss-20b") == ["us"]
        assert get_available_profiles_for_model("invalid-model") == []

    def test_get_model_id_for_profile(self):
        """Test getting model IDs for specific profiles."""
        assert get_model_id_for_profile("gpt-5.4", "us") == "openai.gpt-5.4"
        assert get_model_id_for_profile("gpt-oss-120b", "us") == "openai.gpt-oss-120b"
        assert get_model_id_for_profile("gpt-oss-20b", "us") == "openai.gpt-oss-20b"

        with pytest.raises(ValueError, match="Unknown model"):
            get_model_id_for_profile("invalid-model", "us")

        with pytest.raises(ValueError, match="not available in profile"):
            get_model_id_for_profile("gpt-oss-120b", "europe")

    def test_get_default_region_for_profile(self):
        """Test getting default regions for profiles."""
        assert get_default_region_for_profile("us") == "us-west-2"

        with pytest.raises(ValueError, match="Unknown profile"):
            get_default_region_for_profile("europe")

        with pytest.raises(ValueError, match="Unknown profile"):
            get_default_region_for_profile("invalid-profile")

    def test_get_source_regions_for_model_profile(self):
        """Test getting source regions for model profiles."""
        source_regions = get_source_regions_for_model_profile("gpt-oss-120b", "us")
        assert isinstance(source_regions, list)
        assert len(source_regions) > 0
        assert "us-east-1" in source_regions
        assert "us-east-2" in source_regions
        assert "us-west-2" in source_regions

        with pytest.raises(ValueError, match="Unknown model"):
            get_source_regions_for_model_profile("invalid-model", "us")

        with pytest.raises(ValueError, match="not available in profile"):
            get_source_regions_for_model_profile("gpt-oss-120b", "europe")

    def test_get_destination_regions_for_model_profile(self):
        """Test getting destination regions for model profiles."""
        dest_regions = get_destination_regions_for_model_profile("gpt-oss-120b", "us")
        assert isinstance(dest_regions, list)
        assert len(dest_regions) > 0

        with pytest.raises(ValueError, match="Unknown model"):
            get_destination_regions_for_model_profile("invalid-model", "us")

        with pytest.raises(ValueError, match="not available in profile"):
            get_destination_regions_for_model_profile("gpt-oss-20b", "europe")

    def test_get_all_model_display_names(self):
        """Test getting all model display names."""
        display_names = get_all_model_display_names()

        expected_entries = set()
        for _model_key, model_config in BEDROCK_MODELS.items():
            for _profile_key, profile_config in model_config["profiles"].items():
                expected_entries.add(profile_config["model_id"])

        assert set(display_names.keys()) == expected_entries

        # US profile gets base name only
        assert display_names["openai.gpt-5.4"] == "GPT-5.4"
        assert display_names["openai.gpt-oss-120b"] == "GPT-OSS 120B"
        assert display_names["openai.gpt-oss-20b"] == "GPT-OSS 20B"

    def test_get_profile_description(self):
        """Test getting profile descriptions."""
        desc = get_profile_description("gpt-5.4", "us")
        assert "us-east-1" in desc

        desc = get_profile_description("gpt-oss-120b", "us")
        assert "us-east-1" in desc

        desc = get_profile_description("gpt-oss-20b", "us")
        assert "us-east-1" in desc

        with pytest.raises(ValueError, match="Unknown model"):
            get_profile_description("invalid-model", "us")

        with pytest.raises(ValueError, match="not available in profile"):
            get_profile_description("gpt-oss-120b", "europe")

    def test_model_availability_consistency(self):
        """Test that model availability is consistent across functions."""
        for model_key in BEDROCK_MODELS.keys():
            available_profiles = get_available_profiles_for_model(model_key)

            for profile_key in available_profiles:
                model_id = get_model_id_for_profile(model_key, profile_key)
                description = get_profile_description(model_key, profile_key)
                source_regions = get_source_regions_for_model_profile(model_key, profile_key)
                dest_regions = get_destination_regions_for_model_profile(model_key, profile_key)

                assert isinstance(model_id, str)
                assert isinstance(description, str)
                assert isinstance(source_regions, list)
                assert isinstance(dest_regions, list)

                display_names = get_all_model_display_names()
                assert model_id in display_names

    def test_us_regions_only(self):
        """Test that all models are US-only with correct region list."""
        expected_us_regions = {"us-east-1", "us-east-2", "us-west-2"}

        for model_key in BEDROCK_MODELS.keys():
            profiles = get_available_profiles_for_model(model_key)
            assert profiles == ["us"], f"{model_key} should only have US profile"

            source_regions = get_source_regions_for_model_profile(model_key, "us")
            assert set(source_regions) == expected_us_regions

    def test_bare_mantle_model_ids(self):
        """Test that model IDs use bare Bedrock Mantle format (no regional prefix)."""
        assert get_model_id_for_profile("gpt-5.4", "us") == "openai.gpt-5.4"
        assert get_model_id_for_profile("gpt-oss-120b", "us") == "openai.gpt-oss-120b"
        assert get_model_id_for_profile("gpt-oss-20b", "us") == "openai.gpt-oss-20b"

        # Verify no regional prefix is used
        for _model_key, model_config in BEDROCK_MODELS.items():
            for _profile_key, profile_config in model_config["profiles"].items():
                model_id = profile_config["model_id"]
                assert not model_id.startswith("us."), f"Should not have us. prefix: {model_id}"
                assert not model_id.startswith("eu."), f"Should not have eu. prefix: {model_id}"
                assert not model_id.startswith("apac."), f"Should not have apac. prefix: {model_id}"
