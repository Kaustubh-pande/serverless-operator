# DO NOT EDIT! Generated Dockerfile for openshift-knative-operator/cmd/openshift-knative-operator.
ARG GO_BUILDER=registry.ci.openshift.org/openshift/release:rhel-8-release-golang-1.23-openshift-4.19
ARG GO_RUNTIME=registry.access.redhat.com/ubi8/ubi-minimal

FROM $GO_BUILDER as builder

WORKDIR /workspace
COPY . .

ENV CGO_ENABLED=1
ENV GOEXPERIMENT=strictfipsruntime

RUN go build -tags strictfipsruntime -o /usr/bin/main ./openshift-knative-operator/cmd/openshift-knative-operator

FROM $GO_RUNTIME

ARG VERSION=

COPY --from=builder /usr/bin/main /usr/bin/openshift-knative-operator
COPY LICENSE /licenses/

ENV KO_DATA_PATH="/var/run/ko"
COPY openshift-knative-operator/cmd/openshift-knative-operator/kodata $KO_DATA_PATH

USER 65532

LABEL \
      com.redhat.component="openshift-serverless-1-openshift-knative-operator-rhel8-container" \
      name="openshift-serverless-1/openshift-knative-operator-rhel8" \
      version=$VERSION \
      summary="Red Hat OpenShift Serverless 1 Openshift Knative Operator" \
      maintainer="serverless-support@redhat.com" \
      description="Red Hat OpenShift Serverless 1 Openshift Knative Operator" \
      io.k8s.display-name="Red Hat OpenShift Serverless 1 Openshift Knative Operator" \
      io.k8s.description="Red Hat OpenShift Serverless Openshift Knative Operator" \
      io.openshift.tags="openshift-knative-operator"

ENTRYPOINT ["/usr/bin/openshift-knative-operator"]
