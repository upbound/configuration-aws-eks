import models.io.upbound.awsm.eks.v1beta1 as eksv1beta1
import models.io.upbound.awsm.iam.v1beta1 as iamv1beta1
import models.io.upbound.dev.meta.v1alpha1 as metav1alpha1
import models.io.upbound.platform.aws.v1alpha1 as platformawsv1alpha1

# An injected external-name makes Crossplane observe the existing AWS object
# instead of creating a duplicate. The PodIdentityAssociation's identifier is
# assigned by AWS and cannot be predicted, so a control plane with no prior
# state has no other way to adopt it. Resources absent from the map are
# unaffected.
_xrExternalNames = platformawsv1alpha1.EKS{
    metadata: {
        name: "configuration-aws-eks"
        namespace: "default"
    }
    spec: {
        parameters: {
            id: "configuration-aws-eks"
            region: "us-west-2"
            nodes: {
                count: 1
                instanceType: "t3.small"
            }
            externalNames: {
                ebsCSIDriverPodIdentityAssociation: "a-abcdefghij1234567"
            }
        }
    }
}

# Backward compatibility. With naming unset the XRD defaults it to Generated,
# which must emit no metadata.name at all - Crossplane assigns
# generateName + a random suffix, exactly as it does today. A composed resource
# that gained a name here would be destroyed and recreated on every consumer
# that bumps this configuration.
_xrGenerated = platformawsv1alpha1.EKS{
    metadata: {
        name: "configuration-aws-eks"
        namespace: "default"
    }
    spec: {
        parameters: {
            id: "configuration-aws-eks"
            region: "us-west-2"
            nodes: {
                count: 1
                instanceType: "t3.small"
            }
        }
    }
}

_xrDeterministic = platformawsv1alpha1.EKS{
    metadata: {
        name: "configuration-aws-eks"
        namespace: "default"
    }
    spec: {
        parameters: {
            id: "configuration-aws-eks"
            region: "us-west-2"
            naming: "Deterministic"
            nodes: {
                count: 1
                instanceType: "t3.small"
            }
        }
    }
}

# status.eks.clusterName is read by configuration-aws-ctp for EKS Pod Identity
# and the AWS Load Balancer Controller. It is copied from the observed Cluster's
# metadata.name, so it has to track whichever naming mode is in force. The status
# is only populated from observed composed resources, so these two cases feed one
# in rather than relying on a first-pass render.
_observedCluster = lambda clusterName: str -> eksv1beta1.Cluster {
    eksv1beta1.Cluster{
        metadata: {
            annotations: {
                "crossplane.io/composition-resource-name": "kubernetesCluster"
            }
            name: clusterName
            namespace: "default"
        }
        spec: {
            forProvider: {
                region: "us-west-2"
            }
        }
        status: {
            atProvider: {
                id: "test-kubernetes-cluster"
            }
        }
    }
}

_items = [
    metav1alpha1.CompositionTest{
        metadata.name: "eks-external-names"
        spec= {
            compositionPath: "apis/eks/composition.yaml"
            xrdPath: "apis/eks/definition.yaml"
            timeoutSeconds: 60
            validate: False
            xr: _xrExternalNames
            assertResources: [
                eksv1beta1.PodIdentityAssociation{
                    metadata: {
                        annotations: {
                            "crossplane.io/composition-resource-name": "ebsCSIDriverPodIdentityAssociation"
                            "crossplane.io/external-name": "a-abcdefghij1234567"
                        }
                    }
                    # forProvider.region is required by the generated model, so a
                    # metadata-only fixture will not compile.
                    spec: {
                        forProvider: {
                            region: "us-west-2"
                        }
                    }
                }
            ]
        }
    }
    metav1alpha1.CompositionTest{
        metadata.name: "eks-naming-generated-is-unnamed"
        spec= {
            compositionPath: "apis/eks/composition.yaml"
            xrdPath: "apis/eks/definition.yaml"
            timeoutSeconds: 60
            validate: False
            xr: _xrGenerated
            assertResources: [
                eksv1beta1.Cluster{
                    metadata: {
                        annotations: {
                            "crossplane.io/composition-resource-name": "kubernetesCluster"
                        }
                        generateName = "configuration-aws-eks-"
                    }
                    spec: {
                        forProvider: {
                            region: "us-west-2"
                        }
                    }
                }
            ]
        }
    }
    metav1alpha1.CompositionTest{
        metadata.name: "eks-naming-deterministic"
        spec= {
            compositionPath: "apis/eks/composition.yaml"
            xrdPath: "apis/eks/definition.yaml"
            timeoutSeconds: 60
            validate: False
            xr: _xrDeterministic
            assertResources: [
                eksv1beta1.Cluster{
                    metadata: {
                        annotations: {
                            "crossplane.io/composition-resource-name": "kubernetesCluster"
                        }
                        name = "configuration-aws-eks-eks"
                    }
                    spec: {
                        forProvider: {
                            region: "us-west-2"
                        }
                    }
                }
                iamv1beta1.Role{
                    metadata: {
                        annotations: {
                            "crossplane.io/composition-resource-name": "controlplaneRole"
                        }
                        name = "configuration-aws-eks-eks-controlplane"
                    }
                    spec: {
                        forProvider: {}
                    }
                }
                iamv1beta1.Role{
                    metadata: {
                        annotations: {
                            "crossplane.io/composition-resource-name": "nodegroupRole"
                        }
                        name = "configuration-aws-eks-eks-nodegroup"
                    }
                    spec: {
                        forProvider: {}
                    }
                }
                iamv1beta1.Role{
                    metadata: {
                        annotations: {
                            "crossplane.io/composition-resource-name": "ebsCSIDriverRole"
                        }
                        name = "configuration-aws-eks-ebs-csi"
                    }
                    spec: {
                        forProvider: {}
                    }
                }
            ]
        }
    }
    metav1alpha1.CompositionTest{
        metadata.name: "eks-status-cluster-name-generated"
        spec= {
            compositionPath: "apis/eks/composition.yaml"
            xrdPath: "apis/eks/definition.yaml"
            timeoutSeconds: 60
            validate: False
            xr: _xrGenerated
            observedResources: [
                _observedCluster("configuration-aws-eks-7f8797638036")
            ]
            assertResources: [
                platformawsv1alpha1.EKS{
                    metadata: {
                        name: "configuration-aws-eks"
                        namespace: "default"
                    }
                    spec: _xrGenerated.spec
                    status: {
                        eks: {
                            clusterName: "configuration-aws-eks-7f8797638036"
                        }
                    }
                }
            ]
        }
    }
    metav1alpha1.CompositionTest{
        metadata.name: "eks-status-cluster-name-deterministic"
        spec= {
            compositionPath: "apis/eks/composition.yaml"
            xrdPath: "apis/eks/definition.yaml"
            timeoutSeconds: 60
            validate: False
            xr: _xrDeterministic
            observedResources: [
                _observedCluster("configuration-aws-eks-eks")
            ]
            assertResources: [
                platformawsv1alpha1.EKS{
                    metadata: {
                        name: "configuration-aws-eks"
                        namespace: "default"
                    }
                    spec: _xrDeterministic.spec
                    status: {
                        eks: {
                            clusterName: "configuration-aws-eks-eks"
                        }
                    }
                }
            ]
        }
    }
]
items= _items
