#!/usr/bin/env bash

# Description: Kyma Upgradeability plan on GKE. The purpose of this script is to install last Kyma release on real GKE cluster, upgrade it with current changes and trigger testing.
#
#
# Expected vars:
#
#  - REPO_OWNER - Set up by prow, repository owner/organization
#  - REPO_NAME - Set up by prow, repository name
#  - BUILD_TYPE - Set up by prow, pr/master/release
#  - DOCKER_PUSH_REPOSITORY - Docker repository hostname
#  - DOCKER_PUSH_DIRECTORY - Docker "top-level" directory (with leading "/")
#  - KYMA_PROJECT_DIR - directory path with Kyma sources to use for installation
#  - CLOUDSDK_CORE_PROJECT - GCP project for all GCP resources used during execution (Service Account, IP Address, DNS Zone, image registry etc.)
#  - CLOUDSDK_COMPUTE_REGION - GCP compute region
#  - CLOUDSDK_DNS_ZONE_NAME - GCP zone name (not its DNS name!)
#  - GOOGLE_APPLICATION_CREDENTIALS - GCP Service Account key file path
#  - MACHINE_TYPE (optional): GKE machine type
#  - CLUSTER_VERSION (optional): GKE cluster version
#  - KYMA_ARTIFACTS_BUCKET: GCP bucket
#  - BOT_GITHUB_TOKEN: Bot github token used for API queries
#
# Permissions: In order to run this script you need to use a service account with permissions equivalent to the following GCP roles:
#  - Compute Admin
#  - Kubernetes Engine Admin
#  - Kubernetes Engine Cluster Admin
#  - DNS Administrator
#  - Service Account User
#  - Storage Admin
#  - Compute Network Admin

set -o errexit

discoverUnsetVar=false

for var in REPO_OWNER REPO_NAME DOCKER_PUSH_REPOSITORY KYMA_PROJECT_DIR CLOUDSDK_CORE_PROJECT CLOUDSDK_COMPUTE_REGION GOOGLE_APPLICATION_CREDENTIALS KYMA_ARTIFACTS_BUCKET BOT_GITHUB_TOKEN GCR_PUSH_GOOGLE_APPLICATION_CREDENTIALS; do
    if [[ -z "${!var}" ]] ; then
        echo "ERROR: $var is not set"
        discoverUnsetVar=true
    fi
done
if [[ "${discoverUnsetVar}" = true ]] ; then
    exit 1
fi

#Exported variables
export TEST_INFRA_SOURCES_DIR="${KYMA_PROJECT_DIR}/test-infra"
export KYMA_SOURCES_DIR="${KYMA_PROJECT_DIR}/kyma"
export KYMA_SCRIPTS_DIR="${KYMA_SOURCES_DIR}/installation/scripts"
export TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS="${TEST_INFRA_SOURCES_DIR}/prow/scripts/cluster-integration/helpers"
export KYMA_INSTALL_TIMEOUT="30m"
export KYMA_UPDATE_TIMEOUT="25m"
export UPGRADE_TEST_PATH="${KYMA_SOURCES_DIR}/tests/end-to-end/upgrade/chart/upgrade"
# timeout in sec for helm operation install/test
export UPGRADE_TEST_HELM_TIMEOUT_SEC=10000s
# timeout in sec for e2e upgrade test pods until they reach the terminating state
export UPGRADE_TEST_TIMEOUT_SEC=600
export UPGRADE_TEST_NAMESPACE="e2e-upgrade-test"
export UPGRADE_TEST_RELEASE_NAME="${UPGRADE_TEST_NAMESPACE}"
export UPGRADE_TEST_RESOURCE_LABEL="kyma-project.io/upgrade-e2e-test"
export UPGRADE_TEST_LABEL_VALUE_PREPARE="prepareData"
export UPGRADE_TEST_LABEL_VALUE_EXECUTE="executeTests"
export TEST_CONTAINER_NAME="runner"

# shellcheck disable=SC1090
source "${TEST_INFRA_SOURCES_DIR}/prow/scripts/library.sh"

cleanup() {
    ## Save status of failed script execution
    EXIT_STATUS=$?

    if [[ "${ERROR_LOGGING_GUARD}" = "true" ]]; then
        shout "AN ERROR OCCURED! Take a look at preceding log entries."
        echo
    fi

    #Turn off exit-on-error so that next step is executed even if previous one fails.
    set +e

    if [[ -n "${CLEANUP_CLUSTER}" ]]; then
        shout "Deprovision cluster: \"${CLUSTER_NAME}\""
        date

        #save disk names while the cluster still exists to remove them later
        DISKS=$(kubectl get pvc --all-namespaces -o jsonpath="{.items[*].spec.volumeName}" | xargs -n1 echo)
        export DISKS

        #Delete cluster
        "${TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS}/deprovision-gke-cluster.sh"

        #Delete orphaned disks
        shout "Delete orphaned PVC disks..."
        date
        "${TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS}/delete-disks.sh"
    fi

    if [[ -n "${CLEANUP_DOCKER_IMAGE}" ]]; then
        shout "Delete temporary Kyma-Installer Docker image"
        date
        "${TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS}/delete-image.sh"
    fi

    MSG=""
    if [[ ${EXIT_STATUS} -ne 0 ]]; then MSG="(exit status: ${EXIT_STATUS})"; fi
    shout "Job is finished ${MSG}"
    date
    set -e

    exit "${EXIT_STATUS}"
}

trap cleanup EXIT INT

if [[ "${BUILD_TYPE}" == "pr" ]]; then
    shout "Execute Job Guard"
    "${TEST_INFRA_SOURCES_DIR}/development/jobguard/scripts/run.sh"
fi

function generateAndExportClusterName() {
    readonly REPO_OWNER=$(echo "${REPO_OWNER}" | tr '[:upper:]' '[:lower:]')
    readonly REPO_NAME=$(echo "${REPO_NAME}" | tr '[:upper:]' '[:lower:]')
    readonly RANDOM_NAME_SUFFIX=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c10)

    if [[ "$BUILD_TYPE" == "pr" ]]; then
        readonly COMMON_NAME_PREFIX="gke-upgrade-pr"
        # In case of PR, operate on PR number
        COMMON_NAME=$(echo "${COMMON_NAME_PREFIX}-${PULL_NUMBER}-${RANDOM_NAME_SUFFIX}" | tr "[:upper:]" "[:lower:]")
    elif [[ "$BUILD_TYPE" == "release" ]]; then
        readonly COMMON_NAME_PREFIX="gke-upgrade-rel"
        readonly SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
        readonly RELEASE_VERSION=$(cat "${SCRIPT_DIR}/../../RELEASE_VERSION")
        shout "Reading release version from RELEASE_VERSION file, got: ${RELEASE_VERSION}"
        COMMON_NAME=$(echo "${COMMON_NAME_PREFIX}-${RANDOM_NAME_SUFFIX}" | tr "[:upper:]" "[:lower:]")
    else
        # Otherwise (master), operate on triggering commit id
        readonly COMMON_NAME_PREFIX="gke-upgrade-commit"
        COMMIT_ID=$(cd "$KYMA_SOURCES_DIR" && git rev-parse --short HEAD)
        COMMON_NAME=$(echo "${COMMON_NAME_PREFIX}-${COMMIT_ID}-${RANDOM_NAME_SUFFIX}" | tr "[:upper:]" "[:lower:]")
    fi

    ### Cluster name must be less than 40 characters!
    export CLUSTER_NAME="${COMMON_NAME}"

    export GCLOUD_NETWORK_NAME="${COMMON_NAME_PREFIX}-net"
    export GCLOUD_SUBNET_NAME="${COMMON_NAME_PREFIX}-subnet"
}

function createNetwork() {
    export GCLOUD_PROJECT_NAME="${CLOUDSDK_CORE_PROJECT}"
    NETWORK_EXISTS=$("${TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS}/network-exists.sh")
    if [ "$NETWORK_EXISTS" -gt 0 ]; then
        shout "Create ${GCLOUD_NETWORK_NAME} network with ${GCLOUD_SUBNET_NAME} subnet"
        date
        "${TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS}/create-network-with-subnet.sh"
    else
        shout "Network ${GCLOUD_NETWORK_NAME} exists"
    fi
}

function createCluster() {
    shout "Provision cluster: \"${CLUSTER_NAME}\""
    date
    ### For provision-gke-cluster.sh
    export GCLOUD_SERVICE_KEY_PATH="${GOOGLE_APPLICATION_CREDENTIALS}"
    export GCLOUD_PROJECT_NAME="${CLOUDSDK_CORE_PROJECT}"
    export GCLOUD_COMPUTE_ZONE="${CLOUDSDK_COMPUTE_ZONE}"
    if [[ -z "${MACHINE_TYPE}" ]]; then
        export MACHINE_TYPE="${DEFAULT_MACHINE_TYPE}"
    fi
    if [[ -z "${CLUSTER_VERSION}" ]]; then
        export CLUSTER_VERSION="${DEFAULT_CLUSTER_VERSION}"
    fi

    "${TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS}/provision-gke-cluster.sh"
    CLEANUP_CLUSTER="false"
}

function getLastReleaseVersion() {
    version=$(curl --silent --fail --show-error "https://api.github.com/repos/kyma-project/kyma/releases?access_token=${BOT_GITHUB_TOKEN}" \
     | jq -r 'del( .[] | select( (.prerelease == true) or (.draft == true) )) | sort_by(.tag_name | split(".") | map(tonumber)) | .[-1].tag_name')

    echo "${version}"
}

function installKyma() {
    kubectl create clusterrolebinding cluster-admin-binding --clusterrole=cluster-admin --user="$(gcloud config get-value account)"
    mkdir -p /tmp/kyma-gke-upgradeability
    LAST_RELEASE_VERSION=$(getLastReleaseVersion)

    if [ -z "$LAST_RELEASE_VERSION" ]; then
        shoutFail "Couldn't grab latest version from GitHub API, stopping."
        exit 1
    fi

    shout "Install Tiller from version ${LAST_RELEASE_VERSION}"
    date
    kubectl apply -f "https://raw.githubusercontent.com/kyma-project/kyma/${LAST_RELEASE_VERSION}/installation/resources/tiller.yaml"
    "${KYMA_SCRIPTS_DIR}"/is-ready.sh kube-system name tiller

    shout "Apply Kyma config from version ${LAST_RELEASE_VERSION}"
    date
    kubectl create namespace "kyma-installer"

    "${TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS}/create-config-map.sh" --name "core-test-ui-acceptance-overrides" \
        --data "test.acceptance.ui.logging.enabled=true" \
        --label "component=core"

    "${TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS}/create-config-map.sh" --name "application-registry-overrides" \
        --data "application-registry.deployment.args.detailedErrorResponse=true" \
        --label "component=application-connector"

    shout "Use released artifacts from version ${LAST_RELEASE_VERSION}"
    date

    curl -L --silent --fail --show-error "https://github.com/kyma-project/kyma/releases/download/${LAST_RELEASE_VERSION}/kyma-installer-cluster.yaml" --output /tmp/kyma-gke-upgradeability/last-release-installer.yaml
    kubectl apply -f /tmp/kyma-gke-upgradeability/last-release-installer.yaml

    shout "Installation triggered with timeout ${KYMA_INSTALL_TIMEOUT}"
    date
    "${KYMA_SCRIPTS_DIR}"/is-installed.sh --timeout ${KYMA_INSTALL_TIMEOUT}
}

function checkTestPodTerminated() {
    local retry=0
    local runningPods=0
    local succeededPods=0
    local failedPods=0

    while [ "${retry}" -lt "${UPGRADE_TEST_TIMEOUT_SEC}" ]; do
        # check status phase for each testing pods
        for podName in $(kubectl get pods -n "${UPGRADE_TEST_NAMESPACE}" -o json | jq -sr '.[]|.items[].metadata.name')
        do
            runningPods=$((runningPods + 1))
            phase=$(kubectl get pod "${podName}" -n "${UPGRADE_TEST_NAMESPACE}" -o json | jq '.status.phase')
            echo "Test pod '${podName}' has phase: ${phase}"

            if [[ "${phase}" == *"Succeeded"* ]]
            then
                succeededPods=$((succeededPods + 1))
            fi

            if [[ "${phase}" == *"Failed"* ]]; then
                failedPods=$((failedPods + 1))
            fi
        done

        # exit permanently if one of cluster has failed status
        if [ "${failedPods}" -gt 0 ]
        then
            echo "${failedPods} pod(s) has failed status"
            return 1
        fi

        # exit from function if each pod has succeeded status
        if [ "${runningPods}" == "${succeededPods}" ]
        then
            echo "All pods in ${UPGRADE_TEST_NAMESPACE} namespace have succeeded phase"
            return 0
        fi

        # reset all counters and rerun checking
        delta=$((runningPods-succeededPods))
        echo "${delta} pod(s) in ${UPGRADE_TEST_NAMESPACE} namespace have not terminated phase. Retry checking."
        runningPods=0
        succeededPods=0
        retry=$((retry + 1))
        sleep 5
    done

    echo "The maximum number of attempts: ${retry} has been reached"
    return 1
}

createTestResources() {
    shout "Create e2e upgrade test resources"
    date

    DOMAIN=$(kubectl get cm net-global-overrides -n kyma-installer -o jsonpath='{.data.global\.ingress\.domainName}')

    helm install "${UPGRADE_TEST_RELEASE_NAME}" \
        --namespace "${UPGRADE_TEST_NAMESPACE}" \
        --create-namespace \
        "${UPGRADE_TEST_PATH}" \
        --timeout "${UPGRADE_TEST_HELM_TIMEOUT_SEC}" \
        --wait \
        --set global.domainName="${DOMAIN}"

    prepareResult=$?
    if [ "${prepareResult}" != 0 ]; then
        echo "Helm install operation failed: ${prepareResult}"
        exit "${prepareResult}"
    fi

    set +o errexit
    checkTestPodTerminated
    prepareTestResult=$?
    set -o errexit

    echo "Logs for prepare data operation to test e2e upgrade: "
    kubectl logs -n "${UPGRADE_TEST_NAMESPACE}" -l "${UPGRADE_TEST_RESOURCE_LABEL}=${UPGRADE_TEST_LABEL_VALUE_PREPARE}" -c "${TEST_CONTAINER_NAME}"
    if [ "${prepareTestResult}" != 0 ]; then
        echo "Exit status for prepare upgrade e2e tests: ${prepareTestResult}"
        exit "${prepareTestResult}"
    fi
}

function upgradeKyma() {
    shout "Delete the kyma-installation CR and kyma-installer deployment"
    # Remove the finalizer form kyma-installation the merge type is used because strategic is not supported on CRD.
    # More info about merge strategy can be found here: https://tools.ietf.org/html/rfc7386
    kubectl patch Installation kyma-installation -n default --patch '{"metadata":{"finalizers":null}}' --type=merge
    kubectl delete Installation -n default kyma-installation

    # Remove the current installer to prevent it performing any action.
    kubectl delete deployment -n kyma-installer kyma-installer

    if [[ "$BUILD_TYPE" == "release" ]]; then
        echo "Use released artifacts"
        gsutil cp "${KYMA_ARTIFACTS_BUCKET}/${RELEASE_VERSION}/kyma-installer-cluster.yaml" /tmp/kyma-gke-upgradeability/new-release-kyma-installer.yaml
        gsutil cp "${KYMA_ARTIFACTS_BUCKET}/${RELEASE_VERSION}/tiller.yaml" /tmp/kyma-gke-upgradeability/new-tiller.yaml

        shout "Update tiller"
        kubectl apply -f /tmp/kyma-gke-upgradeability/new-tiller.yaml

        shout "Wait untill tiller is correctly rolled out"
        kubectl -n kube-system rollout status deployment/tiller-deploy

        shout "Update kyma installer"
        kubectl apply -f /tmp/kyma-gke-upgradeability/new-release-kyma-installer.yaml
    else
        shout "Build Kyma Installer Docker image"
        date
        COMMIT_ID=$(cd "$KYMA_SOURCES_DIR" && git rev-parse --short HEAD)
        KYMA_INSTALLER_IMAGE="${DOCKER_PUSH_REPOSITORY}${DOCKER_PUSH_DIRECTORY}/gke-upgradeability/${REPO_OWNER}/${REPO_NAME}:COMMIT-${COMMIT_ID}"
        export KYMA_INSTALLER_IMAGE
        "${TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS}/create-image.sh"
        CLEANUP_DOCKER_IMAGE="true"

        KYMA_RESOURCES_DIR="${KYMA_SOURCES_DIR}/installation/resources"
        INSTALLER_YAML="${KYMA_RESOURCES_DIR}/installer.yaml"
        INSTALLER_CR="${KYMA_RESOURCES_DIR}/installer-cr-cluster.yaml.tpl"

        shout "Update tiller"
        kubectl apply -f "${KYMA_RESOURCES_DIR}/tiller.yaml"

        shout "Wait untill tiller is correctly rolled out"
        kubectl -n kube-system rollout status deployment/tiller-deploy

        shout "Manual concatenating and applying installer.yaml and installer-cr-cluster.yaml YAMLs"
        "${KYMA_SCRIPTS_DIR}"/concat-yamls.sh "${INSTALLER_YAML}" "${INSTALLER_CR}" \
        | sed -e 's;image: eu.gcr.io/kyma-project/.*/installer:.*$;'"image: ${KYMA_INSTALLER_IMAGE};" \
        | sed -e "s/__VERSION__/0.0.1/g" \
        | sed -e "s/__.*__//g" \
        | kubectl apply -f-
    fi

    shout "Update triggered with timeout ${KYMA_UPDATE_TIMEOUT}"
    date
    "${KYMA_SCRIPTS_DIR}"/is-installed.sh --timeout ${KYMA_UPDATE_TIMEOUT}

}

remove_addons_if_necessary() {
  tdWithAddon=$(kubectl get td --all-namespaces -l testing.kyma-project.io/require-testing-addon=true -o custom-columns=NAME:.metadata.name --no-headers=true)

  if [ -z "$tdWithAddon" ]
  then
      echo "- Removing ClusterAddonsConfiguration which provides the testing addons"
      removeTestingAddons
      if [[ $? -eq 1 ]]; then
        exit 1
      fi
  else
      echo "- Skipping removing ClusterAddonsConfiguration"
  fi
}

function testKyma() {
    shout "Test Kyma end-to-end upgrade scenarios"
    date

    if [  -f "$(helm home)/ca.pem" ]; then
        local HELM_ARGS="--tls"
    fi

    set +o errexit
    helm test "${UPGRADE_TEST_RELEASE_NAME}" --timeout "${UPGRADE_TEST_HELM_TIMEOUT_SEC}" ${HELM_ARGS}
    testEndToEndResult=$?

    echo "Test e2e upgrade logs: "
    kubectl logs -n "${UPGRADE_TEST_NAMESPACE}" -l "${UPGRADE_TEST_RESOURCE_LABEL}=${UPGRADE_TEST_LABEL_VALUE_EXECUTE}" -c "${TEST_CONTAINER_NAME}"

    if [ "${testEndToEndResult}" != 0 ]; then
        echo "Helm test operation failed: ${testEndToEndResult}"
        exit "${testEndToEndResult}"
    fi
    set -o errexit

    shout "Test Kyma"
    date
    "${KYMA_SCRIPTS_DIR}"/testing.sh
}

# Used to detect errors for logging purposes
ERROR_LOGGING_GUARD="true"

shout "Authenticate with GCP"
date
init

generateAndExportClusterName

createNetwork

createCluster

installKyma

"${TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS}/get-helm-certs.sh"

createTestResources

upgradeKyma

remove_addons_if_necessary

testKyma

shout "Job finished with success"

# Mark execution as successfully
ERROR_LOGGING_GUARD="false"
