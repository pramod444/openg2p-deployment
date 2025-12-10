FROM alpine:20240606

ARG container_user_id=1001
ARG container_group_id=1001
ARG container_user=openg2p
ARG container_group=openg2p

RUN apk add bash vim git curl jq yq && \
    apk add gettext kubectl helm

RUN addgroup -S ${container_group} -g ${container_group_id} && \
    adduser -S ${container_user} -G ${container_group} -u ${container_user_id}

COPY keycloak_init.sh /keycloak_init.sh

USER ${container_user}

ENTRYPOINT [ "bash" ]
CMD ["/keycloak_init.sh"]
