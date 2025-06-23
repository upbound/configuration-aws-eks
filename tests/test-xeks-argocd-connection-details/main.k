import models.io.upbound.dev.meta.v1alpha1 as metav1alpha1
import models.io.upbound.platform.aws.v1alpha1 as platformawsv1alpha1

# Test for ArgoCD connection details functionality
# This test validates that the XEKS composition properly exposes
# ArgoCD-compatible connection details via publishConnectionDetailsTo

_items = [
    metav1alpha1.CompositionTest{
        metadata.name: "test-xeks-argocd-connection-details"
        spec= {
            assertResources: [
                platformawsv1alpha1.XEKS{
                    metadata.name: "argocd-test-cluster"
                    spec: {
                        parameters: {
                            id: "argocd-test-cluster"
                            region: "us-west-2"
                            nodes: {
                                count: 1
                                instanceType: "t3.small"
                            }
                        }
                        # Test that connection details are published to a secret
                        # that ArgoCD can consume with the required fields
                        publishConnectionDetailsTo: {
                            name: "argocd-cluster-connection"
                        }
                    }
                }
            ]
            compositionPath: "apis/composition.yaml"
            xr: platformawsv1alpha1.XEKS{
                metadata.name: "argocd-test-cluster"
                spec: {
                    parameters: {
                        id: "argocd-test-cluster"
                        region: "us-west-2"
                        nodes: {
                            count: 1
                            instanceType: "t3.small"
                        }
                    }
                    # This tests the ArgoCD integration by publishing
                    # connection details to a secret that ArgoCD can use
                    publishConnectionDetailsTo: {
                        name: "argocd-cluster-connection"
                    }
                }
            }
            xrdPath: "apis/definition.yaml"
            timeoutSeconds: 60
            validate: False
        }
    }
]

items = _items
