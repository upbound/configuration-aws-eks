import models.io.upbound.awsm.eks.v1beta1 as eksv1beta1
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
]
items= _items
