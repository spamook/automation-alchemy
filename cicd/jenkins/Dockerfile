# Jenkins controller with its plugins baked in: a restart never downloads anything, and the
# plugin set is versioned together with the pipeline. Configuration comes from JCasC
# (manifests/cicd/jenkins.yaml), so there is no setup wizard.
FROM jenkins/jenkins:2.580.2-lts-jdk21
COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt
