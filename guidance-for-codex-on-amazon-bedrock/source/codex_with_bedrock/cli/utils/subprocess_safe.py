# ABOUTME: Safe subprocess execution utilities with command injection prevention
# ABOUTME: Provides validation and quoting for external commands

"""
Safe subprocess execution utilities.

All subprocess calls in this codebase use list format (not shell=True), which prevents
most command injection attacks. This module provides additional defense-in-depth:

1. Validation helpers for common input types (AWS regions, stack names, profiles)
2. shlex.quote() wrappers for string arguments
3. Documentation of security model for code review

Security Model:
- subprocess.run([cmd, arg1, arg2]) is safe by default (no shell interpretation)
- shell=True is NEVER used in this codebase
- Dynamic arguments come from config files (admin-controlled) or AWS API responses
- User input from CLI options is minimal and validated
"""

import re
import shlex
from pathlib import Path


def validate_aws_region(region: str) -> str:
    """
    Validate AWS region format.

    Args:
        region: AWS region string (e.g., "us-east-1")

    Returns:
        The region if valid

    Raises:
        ValueError: If region format is invalid
    """
    # AWS region format: 2-3 letter prefix, direction, number
    # Examples: us-east-1, eu-west-2, ap-southeast-1, us-gov-west-1
    pattern = r'^[a-z]{2,3}-[a-z]+-\d+$'
    if not re.match(pattern, region):
        raise ValueError(f"Invalid AWS region format: {region}")
    return region


def validate_stack_name(stack_name: str) -> str:
    """
    Validate CloudFormation stack name.

    Stack names must match: [a-zA-Z][-a-zA-Z0-9]*

    Args:
        stack_name: Stack name to validate

    Returns:
        The stack name if valid

    Raises:
        ValueError: If stack name format is invalid
    """
    pattern = r'^[a-zA-Z][-a-zA-Z0-9]*$'
    if not re.match(pattern, stack_name) or len(stack_name) > 128:
        raise ValueError(f"Invalid stack name format: {stack_name}")
    return stack_name


def validate_profile_name(profile: str) -> str:
    """
    Validate AWS CLI profile name.

    Profile names should be alphanumeric with hyphens/underscores.

    Args:
        profile: Profile name to validate

    Returns:
        The profile name if valid

    Raises:
        ValueError: If profile name contains suspicious characters
    """
    pattern = r'^[a-zA-Z0-9_-]+$'
    if not re.match(pattern, profile) or len(profile) > 64:
        raise ValueError(f"Invalid profile name format: {profile}")
    return profile


def quote_arg(arg: str | Path) -> str:
    """
    Safely quote a command argument.

    When building subprocess commands, this provides defense-in-depth even though
    list format already prevents injection.

    Args:
        arg: String or Path argument

    Returns:
        Safely quoted string
    """
    if isinstance(arg, Path):
        arg = str(arg)
    return shlex.quote(arg)


def build_aws_cli_cmd(
    command: list[str],
    *,
    profile: str | None = None,
    region: str | None = None,
) -> list[str]:
    """
    Build AWS CLI command with validated optional parameters.

    Args:
        command: Base AWS CLI command (e.g., ["aws", "s3", "ls"])
        profile: Optional AWS profile (validated)
        region: Optional AWS region (validated)

    Returns:
        Complete command list ready for subprocess.run()

    Example:
        >>> build_aws_cli_cmd(["aws", "s3", "ls"], profile="prod", region="us-east-1")
        ["aws", "s3", "ls", "--profile", "prod", "--region", "us-east-1"]
    """
    cmd = command.copy()

    if profile:
        validate_profile_name(profile)
        cmd.extend(["--profile", profile])

    if region:
        validate_aws_region(region)
        cmd.extend(["--region", region])

    return cmd
