#!/usr/bin/env python3
"""Mint the lab CI identity token (HS256 JWT) that the lab's push hook hands to `ptc guide action-run`.

PTC's lab issuer (enabled only when the server has ENV GUIDE_LAB_CI_SECRET) verifies it the way it verifies a
GitHub/GitLab OIDC token: signature, iss, aud, exp, and the run claims (repository/project_path = the session's
repository, sha = the posted commit_sha).

Usage (lab CI hook, labci user):
    export GUIDE_LAB_CI_SECRET=...          # same value as the PTC server's ENV
    PTC_CI_ID_TOKEN=$(mint-lab-ci-token.py --repository <session repo path> --sha "$SHA" --ref "refs/heads/$BRANCH")
    PTC_CI_ID_TOKEN="$PTC_CI_ID_TOKEN" ptc-cli.sh guide action-run --config-file .ptc-config.yml

Claims (all strings except iat/nbf/exp):
    iss  "ptc-lab"            aud  "ptc"
    sub  "repo:<repository>:ref:<ref>"
    repository    <repository>    (GitHub claim name)
    project_path  <repository>    (GitLab claim name; same value, so either verifier branch matches)
    sha  <40-hex commit>      ref  <refs/heads/branch>
    iat, nbf = now; exp = now + ttl (default 600 s); jti = random hex
The secret is read from the environment only (never argv).
"""
import argparse, base64, hashlib, hmac, json, os, secrets, sys, time


def b64url(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def mint(secret, repository, sha, ref, ttl=600, iss="ptc-lab", aud="ptc", now=None):
    now = int(now if now is not None else time.time())
    header = {"alg": "HS256", "typ": "JWT"}
    claims = {"iss": iss, "aud": aud, "sub": f"repo:{repository}:ref:{ref}", "repository": repository,
              "project_path": repository, "sha": sha, "ref": ref, "iat": now, "nbf": now, "exp": now + ttl,
              "jti": secrets.token_hex(8)}
    signing = b64url(json.dumps(header, separators=(",", ":")).encode()) + "." + \
        b64url(json.dumps(claims, separators=(",", ":"), sort_keys=True).encode())
    sig = hmac.new(secret.encode(), signing.encode(), hashlib.sha256).digest()
    return signing + "." + b64url(sig)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--repository", required=True, help="the session's repository path (as PTC stores it)")
    ap.add_argument("--sha", required=True)
    ap.add_argument("--ref", default="")
    ap.add_argument("--ttl", type=int, default=600)
    ap.add_argument("--iss", default="ptc-lab")
    ap.add_argument("--aud", default="ptc")
    ap.add_argument("--secret-env", default="GUIDE_LAB_CI_SECRET", help="environment variable holding the secret")
    a = ap.parse_args()
    secret = os.environ.get(a.secret_env, "")
    if not secret:
        sys.stderr.write(f"{a.secret_env} is not set\n")
        return 1
    print(mint(secret, a.repository, a.sha, a.ref, a.ttl, a.iss, a.aud))
    return 0


if __name__ == "__main__":
    sys.exit(main())
