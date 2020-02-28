FROM alpine:edge AS Builder

ARG DUB_OPTIONS
RUN apk --no-cache add build-base jq
RUN apk --no-cache add -X http://dl-cdn.alpinelinux.org/alpine/edge/testing ldc ldc-static dtools-rdmd dub

WORKDIR /root/project/
ADD dub.selections.json /root/project/dub.selections.json
RUN cat dub.selections.json | jq ' .versions | to_entries[] | "dub fetch \(.key) --version=\(.value)" ' -r | xargs -I'{}' /bin/sh -c "{}"

ADD . /root/project/
RUN dub build --compiler=ldc2 ${DUB_OPTIONS}

# Runner
FROM alpine:edge
COPY --from=Builder /root/project/dub-packages-indexer /usr/bin/dub-packages-indexer
RUN apk --no-cache add libexecinfo git libgcc openssh
RUN git config --global user.name "dub-package-indexer"
RUN git config --global user.email "dub-package-indexer@bytecraft.nl"
RUN mkdir -p /root/.ssh
RUN chmod 600 /root/.ssh
RUN echo "github.com ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEAq2A7hRGmdnm9tUDbO9IDSwBK6TbQa+PXYPCPy6rbTrTtw7PHkccKrpp0yVhp5HdEIcKr6pLlVDBfOLX9QUsyCOV0wzfjIJNlGEYsdlLJizHhbn2mUjvSAHQqZETYP81eFzLQNnPHt4EVVUh7VfDESU84KezmD5QlWpXLmvU31/yMf+Se8xhHTvKSCZIFImWwoG6mbUoWf9nzpIoaSjB+weqqUUmpaaasXVal72J+UX2B+2RPW3RcT0eOzQgqlJL3RKrTJvdsjE3JEAvGq3lGHSZXy28G3skua2SmVi/w4yCE6gbODqnTWlg7+wC604ydGXA8VJiS5ap43JXiUFFAaQ==" > /root/.ssh/known_hosts

WORKDIR /root/
ENTRYPOINT [ "/usr/bin/dub-packages-indexer" ]

CMD [ "--fetch", "--upload" ]
