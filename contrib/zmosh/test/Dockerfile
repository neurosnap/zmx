FROM zmx-contrib-test
RUN apt-get update && apt-get install -y openssh-server && rm -rf /var/lib/apt/lists/* && mkdir -p /run/sshd
WORKDIR /app
CMD ["python3", "contrib/zmosh/test/remote_e2e.py", "--scenario", "all"]
