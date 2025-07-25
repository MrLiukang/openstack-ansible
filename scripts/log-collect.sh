#!/usr/bin/env bash

# Copyright 2016, Rackspace US, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# WARNING:
# This file is use by all OpenStack-Ansible roles for testing purposes.
# Any changes here will affect all OpenStack-Ansible role repositories
# with immediate effect.

# PURPOSE:
# This script collects, renames and compresses the logs produced in
# a role test if the host is in OpenStack-CI.

## Vars ----------------------------------------------------------------------
export WORKING_DIR=${WORKING_DIR:-$(pwd)}
export RUN_ARA=${RUN_ARA:-false}
export ARA_REPORT_TYPE=${ARA_REPORT_TYPE:-"database"}
export TESTING_HOME=${TESTING_HOME:-$HOME}
export TS=$(date +"%H-%M-%S")

export RSYNC_CMD="rsync --archive --copy-links --ignore-errors --quiet --no-perms --no-owner --no-group --whole-file --inplace --exclude journal"

# NOTE(cloudnull): This is a very simple list of common directories in /etc we
#                  wish to search for when storing gate artifacts. When adding
#                  things to this list please alphabetize the entries so it's
#                  easy for folks to find and adjust items as needed.
COMMON_ETC_LOG_NAMES="apt \
    apache2 \
    auditd \
    clusterapi \
    corosync \
    ceph \
    dnf \
    etcd \
    exports \
    ganesha \
    gitconfig \
    haproxy \
    httpd \
    ironic-inspector \
    iscsi \
    kubelet \
    letsencrypt \
    memcached \
    mongodb \
    my.cnf \
    mysql \
    mariadb \
    netplan \
    network \
    nginx \
    openstack_deploy \
    openvswitch \
    pacemaker \
    pip.conf \
    qpid-dispatch \
    rabbitmq \
    repo \
    resolv.conf \
    sasl2 \
    ssh \
    step-ca \
    sysconfig/network-scripts \
    sysconfig/network \
    systemd \
    uwsgi \
    yum \
    yum.repos.d \
    zookeeper \
    zypp"

COMMON_ETC_LOG_NAMES+=" $(awk -F'os_' '/name.*os_.*/ {print $2}' $(dirname $(readlink -f ${BASH_SOURCE[0]}))/../ansible-role-requirements.yml | tr '\n' ' ')"

## Functions -----------------------------------------------------------------

function repo_information {
    [[ "${1}" != "host" ]] && lxc_cmd="lxc-attach --name ${1} --" || lxc_cmd=""
    echo "Collecting list of installed packages and enabled repositories for \"${1}\""
    # Redhat package debugging
    if eval sudo ${lxc_cmd} command -v dnf &>/dev/null; then
        eval sudo ${lxc_cmd} dnf repolist -v > "${WORKING_DIR}/logs/redhat-rpm-repolist-${1}-${TS}.txt" || true
        eval sudo ${lxc_cmd} dnf list installed > "${WORKING_DIR}/logs/redhat-rpm-list-installed-${1}-${TS}.txt" || true

    # Ubuntu package debugging
    elif eval sudo ${lxc_cmd} command -v apt-get &> /dev/null; then
        eval sudo ${lxc_cmd} apt-cache policy | grep http | awk '{print $1" "$2" "$3}' | sort -u > "${WORKING_DIR}/logs/ubuntu-apt-repolist-${1}-${TS}.txt" || true
        eval sudo ${lxc_cmd} apt list --installed > "${WORKING_DIR}/logs/ubuntu-apt-list-installed-${1}-${TS}.txt" || true
    fi
}

function store_lxc_artifacts {
    # Store known artifacts only if they exist. If the target directory does
    # exist, it will be created.
    # USAGE: store_lxc_artifacts <container_name> /change/to/dir pattern/to/collect /path/to/store
    CONTAINER_PID=$(sudo lxc-info -p -n ${1} | awk '{print $2}')
    CONTAINER_COLLECT="/proc/${CONTAINER_PID}/root/${2}/${3}"
    if sudo test -e "${CONTAINER_COLLECT}"; then
      if [[ ! -d "${4}" ]]; then
          mkdir -vp "${4}"
      fi
      echo "Running container artifact sync on ${1} collecting ${3} from dir ${2} to ${4}"
      sudo lxc-attach -q -n ${1} -- /bin/bash -c "tar --dereference -c -f - -C ${2} ${3} 2>/dev/null | cat" | tar -C ${4} -x 2>/dev/null
    fi
}

function store_artifacts {
    # Store known artifacts only if they exist. If the target directory does
    # exist, it will be created.
    # USAGE: store_artifacts /src/to/artifacts /path/to/store
    if sudo test -e "${1}"; then
        if [[ ! -d "${2}" ]]; then
            mkdir -vp "${2}"
        fi
        echo "Running artifact sync for \"${1}\" to \"${2}\""
        sudo ${RSYNC_CMD} ${1} ${2} || true
    fi
}

function find_files {
    find "${WORKING_DIR}/logs/" -type f \
        ! -name "*.gz" \
        ! -name '*.html' \
        ! -name '*.subunit' \
        ! -name "*.journal" \
        ! -name 'ansible.sqlite' | grep -Ev 'stackviz|ara-report'
}

function rename_files {
    find_files |\
        while read filename; do \
            mv ${filename} ${filename}.txt || echo "WARNING: Could not rename ${filename}"; \
        done
}

## Main ----------------------------------------------------------------------

echo "#### BEGIN LOG COLLECTION ###"

mkdir -vp "${WORKING_DIR}/logs"

# Gather basic logs
store_artifacts /openstack/log/ansible-logging/ "${WORKING_DIR}/logs/ansible"
store_artifacts /openstack/log/ "${WORKING_DIR}/logs/openstack"
store_artifacts /var/log/ "${WORKING_DIR}/logs/host"

# Build the ARA static html report if required
if [[ "$ARA_REPORT_TYPE" == "html" ]]; then
    echo "Generating ARA static html report."
    /opt/ansible-runtime/bin/ara-manage generate "${WORKING_DIR}/logs/ara-report"
fi

# Store the ara sqlite database in the openstack-ci expected path
store_artifacts "${TESTING_HOME}/.ara/server/ansible.sqlite" "${WORKING_DIR}/logs/ara-report/"

# Store netstat report
store_artifacts /tmp/listening_port_report.txt "${WORKING_DIR}/logs/host"

# Copy the repo os-releases *.txt files
# container path
store_artifacts /openstack/*repo*/repo/os-releases/*/*/*.txt "${WORKING_DIR}/repo"

# metal path
store_artifacts /var/www/repo/os-releases/*/*/*.txt "${WORKING_DIR}/repo"

# Gather container etc artifacts
export -f store_artifacts
IFS=' ' read -a ETC_LOG_NAMES <<< "$COMMON_ETC_LOG_NAMES"
parallel store_artifacts /etc/{1} ${WORKING_DIR}/logs/etc/host ::: "${ETC_LOG_NAMES[@]}"

# Gather container etc artifacts
export -f store_lxc_artifacts
if command -v lxc-ls &> /dev/null; then
  export CONTAINER_NAMES=$(sudo lxc-ls -1)
  parallel store_lxc_artifacts {1} /etc/ {2} ${WORKING_DIR}/logs/etc/openstack/{1} ::: "${CONTAINER_NAMES[@]}" ::: "${ETC_LOG_NAMES[@]}"
  parallel store_lxc_artifacts {1} /var/log/ {2} ${WORKING_DIR}/logs/openstack/{1} ::: "${CONTAINER_NAMES[@]}" ::: "${ETC_LOG_NAMES[@]}"
fi

# gather host and container journals and deprecation warnings
__dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
/opt/ansible-runtime/bin/python ${__dir}/journal_dump.py ${__dir}/../ansible-role-requirements.yml ${COMMON_ETC_LOG_NAMES}

# Rename all files gathered to have a .txt suffix so that the compressed
# files are viewable via a web browser in OpenStack-CI.
rename_files

# Get a dmesg output so we can look for kernel failures
dmesg > "${WORKING_DIR}/logs/dmesg-${TS}.txt" || true

# Collect job environment
env > "${WORKING_DIR}/logs/environment-${TS}.txt"  || true

repo_information host

# Record the active interface configs
if command -v ethtool &> /dev/null; then
    for interface in $(ip -o link | awk -F':' '{print $2}' | sed 's/@.*//g'); do
        echo "ethtool -k ${interface}"
        ethtool -k ${interface} > "${WORKING_DIR}/logs/ethtool-${interface}-${TS}-cfg.txt" || true
    done
else
    echo "No ethtool available" | tee -a "${WORKING_DIR}/logs/ethtool-${TS}-${interface}-cfg.txt"
fi

# Ensure that the files are readable by all users, including the non-root
# OpenStack-CI jenkins user.
sudo chmod -R ugo+rX "${WORKING_DIR}/logs"
sudo chown -R $(whoami) "${WORKING_DIR}/logs"

echo "#### END LOG COLLECTION ###"

