# GitHub Actions Workflows

This directory contains GitHub Actions workflows for testing the Container Discovery script in various environments with different privilege levels.

## Available Workflows

### 1. Comprehensive Test Suite (`test-comprehensive.yml`)
**Recommended for CI/CD**

A comprehensive workflow that uses a test matrix to run all test scenarios in parallel:
- Kubernetes with sudo
- Kubernetes without sudo
- Docker Swarm with sudo
- Docker Swarm without sudo

**Triggers:**
- Push to `main` or `develop` branches
- Pull requests to `main` or `develop` branches
- Manual workflow dispatch

**Features:**
- Test matrix for efficient parallel execution
- Automatic setup of Kubernetes (kind) or Docker Swarm
- JSON validation
- Artifact uploads for test results
- Automatic cleanup

### 2. Kubernetes Test Workflows

#### `test-kubernetes-sudo.yml`
Tests the discovery script in a Kubernetes environment **with sudo privileges**.

**What it does:**
- Sets up a Kubernetes cluster using kind
- Installs crictl for CRI testing
- Runs the discovery script with sudo
- Runs privileged tests
- Validates Kubernetes detection
- Verifies JSON output format

#### `test-kubernetes-no-sudo.yml`
Tests the discovery script in a Kubernetes environment **without sudo privileges**.

**What it does:**
- Sets up a Kubernetes cluster using kind
- Configures kubeconfig for non-root user
- Runs the discovery script without sudo
- Runs unprivileged tests
- Validates graceful degradation

### 3. Docker Swarm Test Workflows

#### `test-docker-swarm-sudo.yml`
Tests the discovery script in a Docker Swarm environment **with sudo privileges**.

**What it does:**
- Initializes Docker Swarm
- Creates test services
- Runs the discovery script with sudo
- Validates Docker Swarm detection
- Verifies node role detection
- Cleans up Swarm resources

#### `test-docker-swarm-no-sudo.yml`
Tests the discovery script in a Docker Swarm environment **without sudo privileges**.

**What it does:**
- Initializes Docker Swarm (with sudo for setup)
- Configures docker socket permissions
- Runs the discovery script without sudo (via docker group)
- Tests graceful degradation
- Cleans up Swarm resources

## Running Workflows Manually

You can trigger any workflow manually from the GitHub Actions tab:

1. Go to the **Actions** tab in your repository
2. Select the workflow you want to run
3. Click **Run workflow**
4. Choose the branch
5. Click **Run workflow** button

## Workflow Outputs

All workflows upload artifacts on completion (successful or failed):

- `output.json` - The container discovery JSON output
- `debug.txt` - Detailed debug logs
- `error.txt` - Error messages (if any)

Artifacts are retained for 7 days and can be downloaded from the workflow run page.

## Understanding Test Results

### Success Criteria

**With sudo:**
- Script completes successfully
- Valid JSON output is generated
- Orchestrators are properly detected
- All cluster components are populated

**Without sudo:**
- Script completes gracefully (exit code 0 or 1)
- Valid JSON output is generated
- Fallback mechanisms work correctly
- No crashes or critical errors

### Expected Behaviors

#### Kubernetes Tests
- **With sudo:** Full detection of Kubernetes cluster, nodes, pods, and components
- **Without sudo:** Limited detection, may miss some components but should not crash

#### Docker Swarm Tests
- **With sudo:** Full detection of Swarm mode, node role, services
- **Without sudo (docker group):** Should detect Swarm if docker socket is accessible

## Privilege Levels Tested

### Sudo Tests
- Simulates running the script as root or with sudo
- Tests full discovery capabilities
- Uses test scripts: `test_privileged.sh`

### No-Sudo Tests
- Simulates running the script as a normal user
- Tests graceful degradation
- Tests fallback mechanisms
- Uses test scripts: `test_unprivileged.sh`

## Local Testing

You can run the same tests locally:

### Kubernetes with kind
```bash
# Install kind
curl -Lo ./kind https://kind.sigs.k8s.io/dl/latest/kind-linux-amd64
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind

# Create cluster
kind create cluster --name test-cluster

# Run tests
sudo ./test_privileged.sh
./test_unprivileged.sh
```

### Docker Swarm
```bash
# Initialize Swarm
sudo docker swarm init

# Create test service
sudo docker service create --name test-nginx --replicas 2 nginx:alpine

# Run tests
sudo ./test_privileged.sh
./test_unprivileged.sh

# Cleanup
sudo docker service rm test-nginx
sudo docker swarm leave --force
```

## Troubleshooting

### Workflow Fails on Kubernetes Setup
- Check if kind action is working properly
- Verify kubectl is installed and configured
- Check cluster initialization logs

### Workflow Fails on Docker Swarm Setup
- Verify Docker is running in the runner
- Check Swarm initialization status
- Verify service creation logs

### JSON Validation Fails
- Check error.txt artifact for error messages
- Verify debug.txt for script execution details
- Review script output for syntax errors

### Artifacts Not Uploaded
- Workflows upload artifacts even on failure (using `if: always()`)
- Check retention period (7 days)
- Verify artifact upload step completed

## Extending the Workflows

### Adding New Test Scenarios

To add a new test scenario to the comprehensive workflow:

```yaml
matrix:
  environment: [kubernetes, docker-swarm, new-environment]
  privilege: [sudo, no-sudo]
```

### Adding New Validation Steps

Add validation steps after the discovery script runs:

```yaml
- name: Custom validation
  run: |
    # Your validation logic here
    jq '.armResources[0].properties.custom_field' output.json
```

### Modifying Triggers

Add or remove triggers in the workflow file:

```yaml
on:
  push:
    branches: [ main, develop, feature/* ]
  schedule:
    - cron: '0 2 * * *'  # Daily at 2 AM
```

## Contributing

When adding new workflows:

1. Test locally first
2. Validate YAML syntax: `yamllint workflow.yml`
3. Use descriptive names
4. Document the workflow in this README
5. Add appropriate artifact uploads
6. Include cleanup steps

## References

- [GitHub Actions Documentation](https://docs.github.com/en/actions)
- [kind (Kubernetes in Docker)](https://kind.sigs.k8s.io/)
- [Docker Swarm Documentation](https://docs.docker.com/engine/swarm/)
- [Container Discovery Script README](../../README.md)
