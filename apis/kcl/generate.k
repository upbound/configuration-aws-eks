import file
import yaml

_composition = {
    apiVersion: "apiextensions.crossplane.io/v1",
    kind: "Composition",
    metadata: {
        name: "kcl.xeks.aws.platform.upbound.io",
        labels: {
            provider: "aws",
            function: "kcl",
        },
    },
    spec: {
        writeConnectionSecretsToNamespace: "upbound-system",
        compositeTypeRef: {
            apiVersion: "aws.platform.upbound.io/v1alpha1"
            kind: "XEKS"
        },
        mode: "Pipeline",
        pipeline: [
            {
                step: "kcl"
                functionRef: {
                    name: "crossplane-contrib-function-kcl"
                }
                input: {
                    apiVersion: "krm.kcl.dev/v1alpha1"
                    kind: "KCLRun"
                    spec: {
                        source = (file.read("apis/kcl/main.k"))
                    }
                }
            },
            {
                step: "automatically-detect-ready-composed-resources"
                functionRef: {
                    name: "crossplane-contrib-function-auto-ready"
                },
            },
            {
                step: "sequence-creation"
                functionRef: {
                    name: "crossplane-contrib-function-sequencer"
                }
                input: {
                    apiVersion: "sequencer.fn.crossplane.io/v1beta1"
                    kind: "Input"
                    rules: [
                        {
                            sequence: [
                                "kubernetesCluster"
                                "kubernetesClusterAuth"
                                "vpc-cni-addon"
                                "nodeGroupPublic"
                            ]
                        },
                        {
                            sequence: [
                                "nodeGroupPublic"
                                "aws-ebs-csi-driver-addon"
                            ]
                        },
                        {
                            sequence: [
                                "nodeGroupPublic"
                                "eks-pod-identity-agent-addon"
                            ]
                        }
                    ]
                }
            }
        ]
    }
}

file.write("apis/kcl/composition.yaml", yaml.encode(_composition))