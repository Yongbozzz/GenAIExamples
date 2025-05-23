#!/bin/bash
# Copyright (C) 2024 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

set -e
IMAGE_REPO=${IMAGE_REPO:-"opea"}
IMAGE_TAG=${IMAGE_TAG:-"latest"}
echo "REGISTRY=IMAGE_REPO=${IMAGE_REPO}"
echo "TAG=IMAGE_TAG=${IMAGE_TAG}"
export REGISTRY=${IMAGE_REPO}
export TAG=${IMAGE_TAG}

WORKPATH=$(dirname "$PWD")
LOG_PATH="$WORKPATH/tests"
ip_address=$(hostname -I | awk '{print $1}')

function build_docker_images() {
    echo "Building Docker Images...."
    cd $WORKPATH/docker_image_build
    if [ ! -d "GenAIComps" ] ; then
        git clone --single-branch --branch "${opea_branch:-"main"}" https://github.com/opea-project/GenAIComps.git
    fi
    service_list="dataprep embedding retriever reranking doc-index-retriever"
    docker compose -f build.yaml build ${service_list} --no-cache > ${LOG_PATH}/docker_image_build.log

    docker pull ghcr.io/huggingface/text-embeddings-inference:cpu-1.5
    docker pull quay.io/coreos/etcd:v3.5.5
    docker pull minio/minio:RELEASE.2023-03-20T20-16-18Z
    docker pull milvusdb/milvus:v2.4.6
    docker images && sleep 1s

    echo "Docker images built!"
}

function start_services() {
    echo "Starting Docker Services...."
    cd $WORKPATH/docker_compose/intel/cpu/xeon
    source ./set_env.sh

    # Start Docker Containers
    docker compose -f compose_milvus.yaml up -d
    sleep 2m
    echo "Docker services started!"
}

function validate() {
    local CONTENT="$1"
    local EXPECTED_RESULT="$2"
    local SERVICE_NAME="$3"

    if echo "$CONTENT" | grep -q "$EXPECTED_RESULT"; then
        echo "[ $SERVICE_NAME ] Content is as expected: $CONTENT."
        echo 0
    else
        echo "[ $SERVICE_NAME ] Content does not match the expected result: $CONTENT"
        echo 1
    fi
}

function validate_megaservice() {
    echo "===========Ingest data=================="
    local CONTENT=$(http_proxy="" curl -X POST "http://${ip_address}:6007/v1/dataprep/ingest" \
     -H "Content-Type: multipart/form-data" \
     -F 'link_list=["https://opea.dev/"]')
    local EXIT_CODE=$(validate "$CONTENT" "Data preparation succeeded" "dataprep-milvus-service-xeon")
    echo "$EXIT_CODE"
    local EXIT_CODE="${EXIT_CODE:0-1}"
    echo "return value is $EXIT_CODE"
    if [ "$EXIT_CODE" == "1" ]; then
        docker logs dataprep-milvus-server | tee -a ${LOG_PATH}/dataprep-milvus-service-xeon.log
        return 1
    fi

    # Curl the Mega Service
    echo "================Testing retriever service ================"
    cd $WORKPATH/tests
    local CONTENT=$(http_proxy="" curl http://${ip_address}:8889/v1/retrievaltool -X POST -H "Content-Type: application/json" -d '{
     "messages": "Explain the OPEA project?"
    }')

    local EXIT_CODE=$(validate "$CONTENT" "OPEA" "doc-index-retriever-service-xeon")
    echo "$EXIT_CODE"
    local EXIT_CODE="${EXIT_CODE:0-1}"
    echo "return value is $EXIT_CODE"
    if [ "$EXIT_CODE" == "1" ]; then
        echo "=============Embedding container log=================="
        docker logs embedding-server | tee -a ${LOG_PATH}/doc-index-retriever-service-xeon.log
        echo "=============Retriever container log=================="
        docker logs retriever-milvus-server | tee -a ${LOG_PATH}/doc-index-retriever-service-xeon.log
        echo "=============TEI Reranking log=================="
        docker logs tei-reranking-server | tee -a ${LOG_PATH}/doc-index-retriever-service-xeon.log
        echo "=============Reranking container log=================="
        docker logs reranking-tei-xeon-server | tee -a ${LOG_PATH}/doc-index-retriever-service-xeon.log
        echo "=============Doc-index-retriever container log=================="
        docker logs doc-index-retriever-server | tee -a ${LOG_PATH}/doc-index-retriever-service-xeon.log
        exit 1
    fi

}

function stop_docker() {
    cd $WORKPATH/docker_compose/intel/cpu/xeon
    container_list=$(cat compose_milvus.yaml | grep container_name | cut -d':' -f2)
    for container_name in $container_list; do
	echo $container_name
        cid=$(docker ps -aq --filter "name=$container_name")
        echo "Stopping container $container_name"
        if [[ ! -z "$cid" ]]; then docker rm $cid -f && sleep 1s; fi
    done
}

function main() {

    stop_docker
    if [[ "$IMAGE_REPO" == "opea" ]]; then build_docker_images; fi
    echo "Dump current docker ps"
    docker ps
    start_time=$(date +%s)
    start_services
    end_time=$(date +%s)
    duration=$((end_time-start_time))
    echo "Mega service start duration is $duration s"
    validate_megaservice

    stop_docker
    echo y | docker system prune

}

main
