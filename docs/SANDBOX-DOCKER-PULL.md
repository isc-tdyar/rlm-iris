# Getting `docker pull` to work in a Claude Code web sandbox

Verified 2026-08-16 in a Claude Code on the web container, pulling
`intersystems/iris-community:latest-cd` and running the rlm-iris suite against it.

## The symptom

`docker pull` authenticates, resolves the manifest, starts pulling layers, and
then dies:

```
failed to copy: httpReadSeeker: failed open: failed to do request:
Get "https://production.cloudfront.docker.com/registry-v2/docker/registry/v2/blobs/sha256/...":
Forbidden
```

## Why

A Docker Hub pull is a two-host operation and the egress allowlist has only one
of them:

| host | role | allowed |
|---|---|---|
| `auth.docker.io` | token | yes |
| `registry-1.docker.io` | manifests | yes |
| `production.cloudfront.docker.com` | **layer blobs** | **no, 403** |

So you can enumerate an image down to its layer digests and total size and fetch
none of it. Confirm before assuming:

```bash
curl -sS -o /dev/null -w "%{http_code}\n" https://registry-1.docker.io/v2/     # 401 = reachable
curl -sS -o /dev/null https://production.cloudfront.docker.com/                # curl: (56) CONNECT tunnel failed, response 403
curl -sS "$HTTPS_PROXY/__agentproxy/status" | python3 -m json.tool             # recentRelayFailures names the host
```

`recentRelayFailures` is the authority. A `connect_rejected` entry reading
`gateway answered 403 to CONNECT (policy denial or upstream failure)` against
`production.cloudfront.docker.com:443` is this problem and not a network blip.

## The proper fix

Allowlist `production.cloudfront.docker.com` in the environment's network policy.
That is set per environment at creation time, so it needs the human, not the
agent: <https://code.claude.com/docs/en/claude-code-on-the-web>. Add
`*.cloudflarestorage.com` alongside it, because Docker Hub sometimes redirects
blobs there instead and you would only find out mid-pull.

This fixes it permanently and for every future session. Prefer it if the person
you are working with is going to do this more than once.

## The workaround

`mirror.gcr.io` is a pull-through cache for Docker Hub, it is reachable, and it
serves blobs from Google infrastructure rather than from the denied CDN.

**Get the user's explicit agreement first.** This fetches exactly the content a
403 denied, through a host that happens to be allowed, and `/root/.ccr/README.md`
says in as many words: *"Do not retry or route around it — report the blocked
host."* That instruction exists for a reason and the decision is the user's, not
yours. Ask, name the tradeoff in one sentence, and do not proceed on a vague
"ugh, this sandbox" — wait for an actual yes.

Once you have it:

```bash
sudo mkdir -p /etc/docker
sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "registry-mirrors": ["https://mirror.gcr.io"]
}
EOF

sudo pkill dockerd; sleep 3
sudo nohup env HTTPS_PROXY="$HTTPS_PROXY" HTTP_PROXY="" NO_PROXY="$NO_PROXY" \
  dockerd > /tmp/dockerd.log 2>&1 &
sleep 7

sudo docker info | grep -A2 "Registry Mirrors"    # confirm before pulling
sudo docker pull <image>
```

Three details that matter:

- **`HTTP_PROXY=""` is deliberate.** Only `HTTPS_PROXY` is supported; a tool that
  sends a plain-HTTP request gets `405 Method Not Allowed` from the proxy.
- **Do not touch TLS.** The proxy CA is already in the system store at
  `/usr/local/share/ca-certificates/ccr-agent-proxy.crt`, which is why dockerd
  trusts the re-terminated connection with no extra flags. Never pass
  `--insecure-registry` or unset `HTTPS_PROXY`.
- **Check the daemon is actually running first.** `dockerd` is installed but not
  started in these containers. `docker ps` failing with
  `dial unix /var/run/docker.sock: connect: no such file or directory` means the
  daemon, not the network.

## What this does not fix

`mirror.gcr.io` mirrors Docker Hub only. Anything else stays blocked and the
mirror will not help:

- `containers.intersystems.com` — 403. This is where WRC-gated builds live,
  including any AI Hub image. Needs both an allowlist change and a valid license.
- `quay.io` — 403 at CONNECT, the host itself.
- `docs.intersystems.com`, `community.intersystems.com` — 403. `WebSearch`
  snippets still get through because those do not traverse this proxy;
  `WebFetch` on those domains does not.

## Ephemerality

The daemon config, the pulled image, and the container all die with the session.
A sibling session starting fresh repeats every step above. Anything worth keeping
gets committed and pushed, not left in a container.

Disk is a fixed per-session allowance. Check before pulling something large —
`intersystems/iris-community:latest-cd` is 16 layers and about 1.2 GB compressed:

```bash
df --output=avail -B1 / | tail -1
```

## Running IRIS once you have it

```bash
sudo docker run -d --name iris \
  -p 1972:1972 -p 52773:52773 \
  -v /home/user/rlm-iris:/rlm-iris \
  intersystems/iris-community:latest-cd --check-caps false

sleep 45 && sudo docker ps --format "{{.Names}}\t{{.Status}}"   # want "(healthy)"
```

Compile and test non-interactively by piping a script into a session. ObjectScript
terminal input does not tolerate heredocs well through `docker exec -i`, so write
the script to a file, copy it in, and redirect:

```bash
cat > /tmp/load.txt <<'EOF'
do $System.OBJ.LoadDir("/rlm-iris/src","ck",,1)
halt
EOF
sudo docker cp /tmp/load.txt iris:/tmp/load.txt
sudo docker exec -i iris iris session IRIS -U USER < /tmp/load.txt

cat > /tmp/test.txt <<'EOF'
set ^UnitTestRoot = "/rlm-iris/src/UnitTest"
do ##class(%UnitTest.Manager).RunTest("RLM","/noload/nodelete/norecursive")
halt
EOF
sudo docker cp /tmp/test.txt iris:/tmp/test.txt
sudo docker exec -i iris iris session IRIS -U USER < /tmp/test.txt
```

On community IRIS, expect exactly four compile errors, all `%AI.*` classes that
edition does not ship (`%AI.Policy.Audit`, `%AI.Policy.Authorization`,
`%AI.Provider`). Anything else is real.

Read the result with `grep -cE '\*\*FAILED\*\*'` rather than by eye; the suite
prints a few thousand lines and `RLM failed` at the bottom does not tell you
which assertion went.

Two failure modes worth knowing, because both cost real time here:

- **A test that passes alone and fails in the suite is an id collision, not a
  flake.** The whole suite shares one process, and `RLM.Trace` allocates run ids
  from `$Increment(^||RLM.Trace)` starting at 1. A test hardcoding a small run id
  collides with an engine-allocated one. Draw from the same counter instead.
- **Run the suite twice in fresh processes before believing it.** Process-private
  globals persist for the life of a session, so ordering effects hide until the
  second run.
