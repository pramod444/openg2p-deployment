# NGINX External Loadbalancer

This folder contains instructions to setup nginx as external Loadbalancer/Reverse Proxy into OpenG2P Cluster.

## Installation

- Install nginx via the OS package manager.
  ```
  sudo apt install nginx
  ```
- Backup the `/etc/nginx/nginx.conf`.
  ```
  sudo cp /etc/nginx/nginx.conf /etc/nginx/nginx.bkp.conf
  ```
- Copy the `nginx.external.lb.sample.conf` into nginx.conf path.
  ```
  sudo cp nginx.external.lb.sample.conf /etc/nginx/nginx.conf
  ```
- Edit the new `/etc/nginx/nginx.conf` file with the correct ips and certificate path, certificate key path, etc. (TODO: Elaborate this step)
- Restart the nginx server.
  ```
  sudo nginx -t
  sudo systemctl restart nginx
  ```