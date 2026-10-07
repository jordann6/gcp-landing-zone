#!/usr/bin/env python3
"""Bake the golden image: pinned role, pinned apt transport, private bake VM."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(os.environ.get("HARDENING_REPO", str(ROOT.parent / "azure-vm-hardening"))).resolve()

# The same cis_baseline release the Azure and AWS zones bake. The tag is
# checked against its commit, so a moved tag fails the build instead of
# silently changing what the image contains.
ROLE_TAG = "v2.0.1"
ROLE_COMMIT = "b5ce929ee940f4ac6a1975ef507db6799e6464f9"

# apt-transport-artifact-registry lives on packages.cloud.google.com, which the
# bake VM cannot reach. The workstation fetches it and Packer uploads it; the
# hash is what makes that safe.
TRANSPORT_URL = ("https://packages.cloud.google.com/apt/pool/apt-transport-artifact-registry-stable/"
                 "apt-transport-artifact-registry_1%3A20260330.01-g1_amd64_76cc1a257456a11d6ae3080cff7a4766.deb")
TRANSPORT_SHA256 = "24ee60aa6f5e0f354d4f52aa504203d2ee324fd6fb12d3bf6dfe7796395b7dfb"

COMPONENTS = "main restricted universe"


def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def capture(args, **kwargs):
    return subprocess.check_output([str(a) for a in args], text=True, **kwargs)


def tf_output(root, name):
    return json.loads(capture(["terraform", f"-chdir={ROOT / root}", "output", "-json", name]))


def extract_role(directory):
    commit = capture(["git", "-C", SOURCE, "rev-parse", f"refs/tags/{ROLE_TAG}^{{commit}}"]).strip()
    if commit != ROLE_COMMIT:
        raise RuntimeError(f"{ROLE_TAG} resolves to {commit}, expected {ROLE_COMMIT}")
    archive = directory / "role.tar"
    run(["git", "-C", SOURCE, "archive", "--format=tar", f"--output={archive}", ROLE_COMMIT,
         "ansible/roles/cis_baseline", "scripts/check-hardening.sh"])
    run(["tar", "-xf", archive, "-C", directory])
    return directory / "ansible" / "roles", directory / "scripts" / "check-hardening.sh"


def fetch_transport(directory):
    path = directory / "apt-transport-artifact-registry.deb"
    # curl, not urllib: it uses the system trust store, which python.org builds
    # on macOS do not until Install Certificates has been run.
    data = subprocess.check_output(["curl", "-fsSL", "--max-time", "60", TRANSPORT_URL])
    digest = hashlib.sha256(data).hexdigest()
    if digest != TRANSPORT_SHA256:
        raise RuntimeError(f"apt transport SHA256 mismatch: got {digest}")
    path.write_bytes(data)
    return path


def wait_for_impersonation(account, attempts=16):
    # A fresh token-creator grant takes minutes to propagate. Packer fails it
    # as an unrelated OS Login error, so wait here and fail clearly instead.
    for _ in range(attempts):
        if subprocess.run(["gcloud", "auth", "print-access-token", f"--impersonate-service-account={account}"],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
            return
        time.sleep(30)
    raise RuntimeError(f"cannot impersonate {account}; check roles/iam.serviceAccountTokenCreator")


def import_oslogin_key(directory, account):
    """Throwaway key in the builder's OS Login profile; returns (user, key path)."""
    key = directory / "bake_ed25519"
    run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "packer-bake", "-f", key])
    profile = json.loads(capture(["gcloud", "compute", "os-login", "ssh-keys", "add",
                                  f"--key-file={key}.pub", "--ttl=2h",
                                  f"--impersonate-service-account={account}", "--format=json"],
                                 stderr=subprocess.DEVNULL))
    users = [a["username"] for a in profile["loginProfile"].get("posixAccounts", []) if a.get("primary")]
    if not users:
        raise RuntimeError(f"{account} has no primary OS Login POSIX account")
    return users[0], key


def remove_oslogin_key(key, account):
    subprocess.run(["gcloud", "compute", "os-login", "ssh-keys", "remove", f"--key-file={key}.pub",
                    f"--impersonate-service-account={account}"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main():
    os.umask(0o077)
    bake = tf_output("image", "bake")
    wait_for_impersonation(bake["builder"])
    mirror = tf_output("image", "apt_mirror")
    sources = "\n".join(f"deb {repo['base']} {suite} {COMPONENTS}" for suite, repo in sorted(mirror.items()))
    with tempfile.TemporaryDirectory(prefix="gcp-lz-image-") as directory:
        directory = Path(directory)
        role_path, check_script = extract_role(directory)
        ssh_user, ssh_key = import_oslogin_key(directory, bake["builder"])
        variables = {
            "project_id": bake["project"],
            "zone": f"{bake['region']}-a",
            "network": bake["network"],
            "subnetwork": bake["subnetwork"],
            "service_account": bake["service_account"],
            "builder_service_account": bake["builder"],
            "ssh_username": ssh_user,
            "ssh_private_key_file": str(ssh_key),
            "apt_sources": sources,
            "transport_deb": str(fetch_transport(directory)),
            "role_path": str(role_path),
            "check_script": str(check_script),
            "role_ref": f"{ROLE_TAG} ({ROLE_COMMIT[:7]})",
        }
        inputs = directory / "build.pkrvars.json"
        inputs.write_text(json.dumps(variables))
        cwd = ROOT / "packer"
        run(["packer", "init", "hardened-ubuntu.pkr.hcl"], cwd=cwd)
        run(["packer", "validate", f"-var-file={inputs}", "hardened-ubuntu.pkr.hcl"], cwd=cwd)
        # Debug log beside the template (gitignored): an IAP or SSH timeout says
        # nothing useful without it.
        env = dict(os.environ, PACKER_LOG="1", PACKER_LOG_PATH=str(cwd / "packer.log"))
        try:
            run(["packer", "build", "-on-error=cleanup", f"-var-file={inputs}", "hardened-ubuntu.pkr.hcl"],
                cwd=cwd, timeout=2400, env=env)
        finally:
            remove_oslogin_key(ssh_key, bake["builder"])
    image = capture(["gcloud", "compute", "images", "describe-from-family", "hardened-ubuntu-2204",
                     f"--project={bake['project']}", f"--impersonate-service-account={bake['builder']}",
                     "--format=value(name)"]).strip()
    print(f"PASS: published {image} to family hardened-ubuntu-2204 in {bake['project']}")


if __name__ == "__main__":
    main()
