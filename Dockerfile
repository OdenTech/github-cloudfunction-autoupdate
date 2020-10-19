FROM google/cloud-sdk:alpine

RUN apk --update --no-cache add git bash py3-pip jq

COPY entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
