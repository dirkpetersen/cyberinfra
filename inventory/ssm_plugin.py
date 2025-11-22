#!/usr/bin/env python3
"""
Dynamic Inventory Script for Ansible - AWS SSM Parameter Store Integration

This script queries AWS Systems Manager Parameter Store to dynamically build
an Ansible inventory from a hierarchical parameter structure.

Expected SSM Parameter Hierarchy:
    /{system_type}/{cluster_id}/{node_id}/{attribute}

Examples:
    /proxmox/cl1/n01/ip           → "10.10.1.11"
    /proxmox/cl1/n01/mac          → "aa:bb:cc:11:22:33"
    /weka/cl1/n01/ip              → "10.10.2.11"
    /weka/cl1/n01/container_id    → "weka-01"
    /ceph/cl1/n02/ip              → "10.10.3.12"
    /nvidia/nvl1/n01/ip           → "10.10.4.11"

Generated Inventory Structure:
    - Top-level groups by system_type: proxmox, weka, ceph, nvidia
    - Cluster groups: cl1, nvl1, etc.
    - Hosts: n01, n02, n03, etc.
    - Host variables from parameter attributes: ip, mac, etc.

Usage:
    # List all hosts
    ./inventory/ssm_plugin.py --list

    # Get specific host details
    ./inventory/ssm_plugin.py --host n01

    # Use with ansible-playbook
    ansible-playbook -i inventory/ssm_plugin.py playbooks/setup_proxmox.yml

Environment Variables:
    AWS_REGION: AWS region for SSM Parameter Store (default: us-west-2)
    AWS_PROFILE: AWS CLI profile to use (optional)
    SSM_PARAMETER_ROOT: Root path for parameters (default: /)
"""

import json
import sys
import os
import argparse
from typing import Dict, List, Any
from collections import defaultdict

try:
    import boto3
    from botocore.exceptions import ClientError, NoCredentialsError
except ImportError:
    print("ERROR: boto3 is required. Install with: pip install boto3", file=sys.stderr)
    sys.exit(1)


class SSMInventory:
    """Build Ansible inventory from AWS SSM Parameter Store."""

    def __init__(self, region: str = "us-west-2", root_path: str = "/"):
        """
        Initialize SSM inventory builder.

        Args:
            region: AWS region for SSM Parameter Store
            root_path: Root path for parameters (default: /)
        """
        self.region = region
        self.root_path = root_path
        self.ssm_client = None
        self.inventory = {
            "_meta": {
                "hostvars": {}
            }
        }

    def _get_ssm_client(self):
        """Get or create SSM client."""
        if self.ssm_client is None:
            try:
                profile = os.environ.get("AWS_PROFILE")
                if profile:
                    session = boto3.Session(profile_name=profile, region_name=self.region)
                    self.ssm_client = session.client("ssm")
                else:
                    self.ssm_client = boto3.client("ssm", region_name=self.region)
            except NoCredentialsError:
                print("ERROR: AWS credentials not found. Configure with 'aws configure'", file=sys.stderr)
                sys.exit(1)
        return self.ssm_client

    def _get_parameters_by_path(self, path: str) -> List[Dict[str, Any]]:
        """
        Recursively fetch all parameters under a path.

        Args:
            path: SSM parameter path

        Returns:
            List of parameter dictionaries
        """
        ssm = self._get_ssm_client()
        parameters = []
        next_token = None

        try:
            while True:
                kwargs = {
                    "Path": path,
                    "Recursive": True,
                    "WithDecryption": True  # Decrypt SecureString parameters
                }
                if next_token:
                    kwargs["NextToken"] = next_token

                response = ssm.get_parameters_by_path(**kwargs)
                parameters.extend(response.get("Parameters", []))

                next_token = response.get("NextToken")
                if not next_token:
                    break

        except ClientError as e:
            error_code = e.response.get("Error", {}).get("Code", "Unknown")
            print(f"ERROR: Failed to fetch parameters from {path}: {error_code}", file=sys.stderr)
            sys.exit(1)

        return parameters

    def _parse_parameter_path(self, param_path: str) -> Dict[str, str]:
        """
        Parse SSM parameter path into components.

        Expected format: /{system_type}/{cluster_id}/{node_id}/{attribute}

        Examples:
            /proxmox/cl1/n01/ip → {system: proxmox, cluster: cl1, node: n01, attr: ip}
            /weka/cl1/n01/container_id → {system: weka, cluster: cl1, node: n01, attr: container_id}
            /proxmox/cl1/shared/token → {system: proxmox, cluster: cl1, node: shared, attr: token}

        Args:
            param_path: SSM parameter path

        Returns:
            Dictionary with keys: system_type, cluster_id, node_id, attribute
        """
        parts = [p for p in param_path.split("/") if p]  # Remove empty strings

        if len(parts) < 4:
            return {}

        return {
            "system_type": parts[0],
            "cluster_id": parts[1],
            "node_id": parts[2],
            "attribute": parts[3]
        }

    def _add_group(self, group_name: str, children: List[str] = None, hosts: List[str] = None):
        """
        Add a group to the inventory.

        Args:
            group_name: Name of the group
            children: List of child group names
            hosts: List of host names
        """
        if group_name not in self.inventory:
            self.inventory[group_name] = {}

        if children:
            self.inventory[group_name]["children"] = children

        if hosts:
            self.inventory[group_name]["hosts"] = hosts

    def _add_host_var(self, host: str, var_name: str, var_value: str):
        """
        Add a variable to a host.

        Args:
            host: Hostname
            var_name: Variable name
            var_value: Variable value
        """
        if host not in self.inventory["_meta"]["hostvars"]:
            self.inventory["_meta"]["hostvars"][host] = {}

        self.inventory["_meta"]["hostvars"][host][var_name] = var_value

    def build_inventory(self) -> Dict[str, Any]:
        """
        Build Ansible inventory from SSM parameters.

        Returns:
            Ansible inventory dictionary
        """
        # Fetch all parameters
        parameters = self._get_parameters_by_path(self.root_path)

        if not parameters:
            print("WARNING: No parameters found in SSM Parameter Store", file=sys.stderr)
            return self.inventory

        # Track system types and clusters
        system_clusters = defaultdict(set)  # {system_type: {cluster1, cluster2}}
        cluster_hosts = defaultdict(set)    # {cluster_id: {host1, host2}}

        # Parse parameters and build inventory structure
        for param in parameters:
            path = param["Name"]
            value = param["Value"]

            parsed = self._parse_parameter_path(path)
            if not parsed:
                continue  # Skip invalid paths

            system_type = parsed["system_type"]
            cluster_id = parsed["cluster_id"]
            node_id = parsed["node_id"]
            attribute = parsed["attribute"]

            # Track relationships
            system_clusters[system_type].add(cluster_id)

            # Skip 'shared' pseudo-nodes - these are cluster-wide variables
            if node_id != "shared":
                cluster_hosts[cluster_id].add(node_id)

                # Add host variable
                self._add_host_var(node_id, attribute, value)

                # Add system_type and cluster_id as host variables
                self._add_host_var(node_id, "system_type", system_type)
                self._add_host_var(node_id, "cluster_id", cluster_id)
            else:
                # Shared parameters go into group_vars (handled by playbooks via lookup)
                pass

        # Build group hierarchy
        for system_type, clusters in system_clusters.items():
            # Add system-level group
            cluster_list = sorted(clusters)
            self._add_group(system_type, children=cluster_list)

            # Add cluster groups
            for cluster_id in clusters:
                hosts = sorted(cluster_hosts[cluster_id])
                self._add_group(cluster_id, hosts=hosts)

        # Set ansible_host from 'ip' attribute for convenience
        for host, hostvars in self.inventory["_meta"]["hostvars"].items():
            if "ip" in hostvars:
                hostvars["ansible_host"] = hostvars["ip"]

        return self.inventory

    def get_host(self, hostname: str) -> Dict[str, Any]:
        """
        Get variables for a specific host.

        Args:
            hostname: Name of the host

        Returns:
            Dictionary of host variables
        """
        # Build full inventory first
        self.build_inventory()
        return self.inventory["_meta"]["hostvars"].get(hostname, {})


def main():
    """Main entry point for dynamic inventory script."""
    parser = argparse.ArgumentParser(
        description="Ansible dynamic inventory from AWS SSM Parameter Store"
    )
    parser.add_argument(
        "--list",
        action="store_true",
        help="List all hosts and groups (Ansible default)"
    )
    parser.add_argument(
        "--host",
        help="Get variables for a specific host"
    )

    args = parser.parse_args()

    # Get configuration from environment
    region = os.environ.get("AWS_REGION", "us-west-2")
    root_path = os.environ.get("SSM_PARAMETER_ROOT", "/")

    inventory = SSMInventory(region=region, root_path=root_path)

    if args.list:
        # Return full inventory
        result = inventory.build_inventory()
        print(json.dumps(result, indent=2))
    elif args.host:
        # Return host-specific variables
        result = inventory.get_host(args.host)
        print(json.dumps(result, indent=2))
    else:
        parser.print_help()
        sys.exit(1)


if __name__ == "__main__":
    main()
