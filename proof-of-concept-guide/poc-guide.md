# Z Observability Connect - POC Deployment Guide

This document provides a step-by-step, cookbook-style guide for setting up a Z Observability Connect Proof of Concept (PoC) in a non-production environment. The goal is to offer a streamlined approach to deploying the required components, validating the setup, and positioning you to evaluate the value that Z Observability Connect delivers by enabling visibility into key observability signals from your own applications.

This guide is supplemental to the official Z Observability Connect documentation. Throughout the document, you’ll find links directing you to specific sections of the official documentation relevant to each step. This guide aims to fill in any gaps, provide additional context, and outline clear, beginning-to-end steps for the deployment process.

Z Observability Connect covers many different use cases and offers a variety of options for integrating various data sources and protocols. You may not need to follow every step of this guide. The `Getting Started` section will provide guidance on which sections of this guide you need to follow based on your goals and selected technologies.

Additionally, this guide will distinguish between critical and optional steps or documentation within each section.

## Z APM Connect 6.2 and Instana for z/OS v1.2 Customers

This documentation applies to Z Observability Connect 7.1. However, if you are a Z APM Connect v6.2 or Instana for z/OS v1.2 customer, you can still follow the section on ZAPM Trace Components. The ZAPM Trace Components in Z Observability Connect 7.1 are the same components used in Z APM Connect 6.2 and Instana for z/OS 1.2, so the instructions provided here remain applicable to those versions.

Please note that some components, such as the Telemetry Controller and the CDP policies for metrics and logs, are only available in Z Observability Connect 7.1 or later versions.

# Getting Started

**Optional:** Read [Z Observability Connect Overview](https://www.ibm.com/docs/en/zapmc/7.1.0?topic=z-observability-connect-overview).


## Choosing Use Cases

Z Observability Connect supports collecting Trace, Metrics and Log data. 

### z/OS Tracing Technologies

Z Observability Connect supports two main paths to instrument z/OS services for collecting trace data:

* Native subsystem emissions as OpenTelemetry
* ZAPM Trace Components, which support incoming traces using:
  * AppDynamics Singularity headers
  * Instana headers
  * W3C headers (OpenTelemetry)

#### Native Subsystem Emissions

If your z/OS subsystems are at supported levels, you can use the native emissions Open Telemetry support for trace data. Review the required subsystem levels here:  [required subsystem levels](https://www.ibm.com/docs/en/zapmc/7.1.0?topic=requirements-additional-software#topic_xr5_2g1_chc__title__8). 

To use native emissions Open Telemetry trace data, **you must install the Z Observability Connect Telemetry Controller** to receive, process, and export OpenTelemetry trace data to an OTel‑compatible observability backend. Follow the instructions for the Telemetry Controller below. 

The native subsystems emissions requires the Telemetry Controller to be installed. You do not need to install the ZAPM Trace Components.

#### ZAPM Trace Components

A set of host and distributed components that capture application trace data from z/OS subsystems. These are the same components previously delivered with Z APM 6.2 and Instana for z/OS 1.2. The solution includes required z/OS components that must be installed on each LPAR, along with a distributed component that processes the collected trace data and sends it to a supported observability backend.

Supported backends include:

* AppDynamics when traces include AppDynamics Singularity headers
* Instana when traces include Instana headers
* Any OpenTelemetry-compatible backend such as Instana, Grafana, Splunk, Elastic, DataDog, Dynatrace, and others

### Open Telemetry Metrics and Logs

Z Observability Connect includes the ability to stream System Management Facility (SMF) records and z/OS syslog data collection. 

To collect and process Open Telemetry Metrics and Logs, install the following:

* Common Data Provider with metrics and logs policies installed
* Telemetry Controller

# Telemetry Controller

The Telemetry Controller should be deployed and used as the OpenTelemetry Collector for any of the following scenarios:

* z/OS applications are being monitored through native subsystem emissions using OpenTelemetry.
* z/OS applications are being monitored through the ZAPM Trace Components and are using OpenTelemetry as their telemetry protocol.
* CDP is streaming metrics and z/OS SYSLOG data to be ingested by an OpenTelemetry‑compatible observability backend.

## Common Issues During a POC

The most common issues that slow down progress of a POC or deployment are the following:

* Insufficient resources
* User permissions
* Firewalls and ports not being accessible

This guide will attempt to provide guidance to avoid these issues. However, when error messages are encountered, they almost always fall into one of these categories.

## Planning and Initial Steps

### Resource Planning

The following page provides resource requirements based on expected traffic levels. A typical POC will use the “small” deployment profile, which targets approximately 60k spans per second and assumes a single Kafka node. You should ensure that the following resources are dedicated to the Telemetry Controller:

* 4 cores
* 4 GB RAM
* 40 GB disk space

These are the minimum recommendations for deployment of the Telemetry Controller. They do not account for additional software running on the same machine and assume lighter traffic appropriate for a POC.

If you plan to run the ZAPM Distributed Gateway and Grafana on the same machine, you should consider a more robust configuration:

* 8 cores
* 16 GB RAM
* 100 GB disk space

When considering permission and allocating volumes, consider default locations for some of the depedencies you may select:

* MicroK8s: default location are `/snap/microk8s` and `/var/snap/microk8s/current/`
* K3s: default locations are `/var/lib/rancher/k3s/` and `/etc/rancher/k3s/k3s.yaml`
* Docker: default locations are `/usr/bin/docker` and `/var/lib/docker/`
* Podman: default location for Rootfull installation is `/var/lib/containers/`

### Provision Machines

The Telemetry Controller can be deployed on a Kubernetes or Open Shift cluster. The Kubernetes cluster must be provisioned on a [supported Linux distribution](https://www.ibm.com/docs/en/zapmc/7.1.0?topic=requirements-additional-software#topic_xr5_2g1_chc__title__2). POCs that are limited to less than 60k Spans per Second can be installed on a 1 node Kubernetes cluster and thus only require 1 machine. 

### Request Access to IBM Cloud Container Registry (ICR).

The easiest installation path is to pull the ZOC images directly from the IBM Cloud Container Registry. The telemetryctl installation program already includes the registry path required to download these images. Before you can use this method, an Enablement Key is required. You can request an entitlement key by opening an IBM Support case. More details are available [here](https://www.ibm.com/docs/en/zapmc/7.1.0?topic=deployment-system-requirements#concept_x4w_5cg_3gc__title__2).

Another option for deploying the Telemetry Controller images is to manually push them to a local image registry. The Telemetry Controller images are included in the Fix Central installation package, which can be useful for air‑gapped environments.

## Prepare the Machine

### Install Kubernetes distribution

The following [Kubernetes distributions](https://www.ibm.com/docs/en/zapmc/7.1.0?topic=requirements-additional-software#topic_xr5_2g1_chc__title__5) are supported. 

For evaluation of POC purposes, using a lightweight Kubernetes deployment will minimize cluster setup. Two recommended choices are:

* [MicroK8s](https://canonical.com/microk8s/docs/getting-started) - Supported on zLinux but requires Snap to be installed. This is a good option for Ubuntu or zLinux.
* [K3s](https://k3s.io/) - A good option for RHEL or x86_amd64 machines.

OPTIONAL: If you need to handle larger amounts of traffic, consider the additional [deployment resource requirements](https://www.ibm.com/docs/en/zapmc/7.1.0?topic=deployment-cluster-resource-planning-telemetry-controller).

Once you have a Kubernetes distribution installed, you can verify it by running:

```
kubectl get pods -A
```
If Kubernetes is installed correctly, you will see pods in the `kube-system` namespace. A status of `Running` or `Completed` indicates a successful installation.


### Helm

[Helm](https://helm.sh/docs/intro/install) is a prerequisite for deployment and should be installed on the main node of the cluster. The following [Helm versions are supported](https://www.ibm.com/docs/en/zapmc/7.1.0?topic=requirements-additional-software#topic_xr5_2g1_chc__title__7). 

You can verify Helm by running:

```
helm version
```

If Helm is installed correctly, the command will return the installed Helm version. 

### Download Fix Central Package

The installation program and configuration files are available for [download on Fix Central](https://www.ibm.com/docs/en/zapmc/7.1.0?topic=deployment-system-requirements#concept_x4w_5cg_3gc__title__3). From this page, click on the IBM Fix Central link to access Fix Central and download the latest package that starts with "TelemetryController". 

When accessing the Fix Central page, if you are not brought directly to the product page, you can locate the correct download using the following selections:

**Product selector:** `IBM Z Observability Connect`  
**Installed Version:** `7.1.0`  
**Platform:** `Linux 64-bit,x86_64` or `Linux390 64-bit`

This package is required for any installation. Once downloaded, extract the Telemetry Controller package. Here is an example—substitute the appropriate architecture and release values based on the downloaded tar.gz file:

```
tar -xvf TelemetryController-<release>-<architecture>.tar.gz
```

### Open External Ports

Review the External ports listed in Table1 Default ports on the [following page](https://www.ibm.com/docs/en/zapmc/7.1.0?topic=deployment-prerequisites-telemetry-controller#tasktask_xf5_4fb_1hc__steps__1). 

### TLS Considerations

If you use Kubernetes, including the recommended lightweight options such as MicroK8s or K3s, you will not need to configure TLS between CDP and the Telemetry Controller. If you deploy using OpenShift, secure routes will be created as part of the configuration, and TLS will be required between CDP and the Telemetry Controller.

## Telemetry Controller Deployment

There are two deployment methods for the Telemetry Controller: using the telemetryctl CLI tool or manually updating values.yaml and deploying with Helm. For a proof‑of‑concept or a simple installation, the telemetryctl installation program is recommended.

### Create Kubernetes Namespace

Create a namespace for the Telemetry Controller components. You can chose any name you want, but the documentation and installation program defaults to `ibm-zoc`. Here is an example:

```
kubectl create namespace ibm-zoc
```

OPTIONAL: You can make the zoc namespace the default so that you don't need to specify the namespace with each kubectl command. For example:

```
kubectl config set-context --current --namespace=ibm-zoc
```

### Update Telemetryctl to use Kubernetes

The telemetryctl installation program needs to know where the kubernetes config is located. 

Edit the file `/telemetry-controller/config.yaml `. 

Find the following section:

```
kubernetes:
  kube_config: "/root/.kube/config"
```

Update kube_config: depending on which distribution of Kubernetes, here are some common default locations of kube_config. Update config.yaml accordingly.  

**K3s**

```
  kube_config: "/etc/rancher/k3s/k3s.yaml"
```

**MicroK8s**

```
  kube_config: "/var/snap/microk8s/current/credentials/client.config"
```

**OpenShift**

```
  kube_config: "/etc/kubernetes/kubeconfig"
```

NOTE: It's possible that the `kube_config` file is located in a different path, especially if you are using a different Kubernetes distribution. Make sure the file you reference actually exists and contains valid Kubernetes configuration information. For example, it may include entries similar to the following:

```
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data:

    ...
```

OPTIONAL: While looking at config.yaml, you can review the other information. For a POC, it's likely the defaults will be appropriate. To view information about options in config.yaml, view the [Telemetryctl CLI Configuration](https://www.ibm.com/docs/en/zapmc/7.1.0?topic=tool-telemetryctl-cli-configuration) page.

## Run telemetryctl

```
./telemetryctl install
```
Step 1 – Kubernetes namespace: If you created the `ibm-zoc` namespace as specified in the steps above, press Enter to accept the default.

Step 2 – Deployment profile: For a POC, choose **Small**, which supports traffic under 60k spans per second.

Step 3 – ICR Registry Images: Unless you have a requirement to host the images locally, it is recommended to pull from ICR. Choose **YES**.

Step 4 – Entitlement key: To access ICR images, you need an enablement key. This can be requested through an IBM Support case.

Step 5 – OpenShift: There are special deployment considerations for OpenShift. If you are using another Kubernetes distribution such as MicroK8s or K3s, select **NO**.

Step 6 – FQDN: Provide the fully qualified hostname of the Linux machine (for example: `observability-poc1.company.com`). The default is `localhost`, but you should enter your actual FQDN rather than accept the default.

Step 7 – Kafka port: For a POC, you can accept the default port **30090** unless you have a conflict or need a different port. If you are also installing the Distributed Gateway on the same machine, you may choose **30091**.

Step 8 – TLS: For the easiest POC deployment, run without TLS initially and enable TLS later if required, after verifying the setup.

Step 9 – Configuration Summary: Take a screenshot or save this information. This table includes the key deployment choices for the Telemetry Controller. Select **YES** to continue.

Step 10 – Deployment Summary: Review the status. 

## Verify pods

Run:
```
kubectl get pods -n ibm-zoc
```
You should see output similar to this:

```
NAME               READY   STATUS    RESTARTS   AGE
kafka-0            1/1     Running   0          2m14s
otel-collector-0   1/1     Running   0          2m14s
otel-collector-1   1/1     Running   0          2m7s
```

To view the otel-collector logs, you can run:

```
kubectl logs otel-collector-0 -n ibm-zoc
```

# CDP with Metrics and Logs Policies

The Common Data Provider (CDP) can be used to collect SMF records and log data and stream that data to Kafka. Z Observability Connect provides CDP policies and configuration for key metrics, including CICS, DB2, IMS, MQ, and SYSLOG data.

To send and process metric and log data, the Telemetry Controller component is required. The Telemetry Controller receives the data from CDP, converts it into OTLP spans/metrics data points/log records, and exports it to any OpenTelemetry‑compatible backend

If you don't have the Common Data Provider installed already, follow these [installation instructions](https://www.ibm.com/docs/en/zcdp/5.1.0?topic=installing-z-common-data-provider). 

Follow the [steps from the online documentation](https://www.ibm.com/docs/en/zapmc/7.1.0?topic=deployment-z-common-data-provider) to configure the collection of SMF metrics and logs and to install the CDP configuration files and policies.


## Sample Grafana Dashboards (Optional)

To visualize trace, metric, and log data in an OpenTelemetry backend, sample Grafana dashboards along with instructions to deploy a complete Grafana stack are provided on the IBM opensource github page. You should download and follow the README instructions at [z-observability-connect](https://github.com/IBM/z-observability-connect/grafana-dashboards).

**Note:** Once Grafana is setup, the README will provide instructions to update and restart the Telemetry Controller to send trace and log data to Grafana and populate the sample dashboards. 

# ZAPM Trace Components

The ZAPM Trace Components are required for native support of Instana spans or AppDynamics Singularity headers. They can also be used to provide OpenTelemetry support as an alternative to the native emissions–based OTEL support when subsystems are not at supported levels.

Review the [documentation for ZAPM Trace Components](https://www.ibm.com/docs/en/zapmc/7.1.0?topic=components-zapm-trace-overview).
