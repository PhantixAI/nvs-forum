-------------------------------------------------------Check App status using SSH--------------------------------------------------------------
Most likely causes in order:
  
    1. Pitchfork is still booting — a full restart takes 60–90 seconds on a 2GB RAM instance. If you checked immediately after the restart, it may just need more time.
    2. Out of memory — the instance has 2GB RAM, 50% was already in use before the restart. Spawning a new mold + 2 workers temporarily doubles memory usage. The OOM killer may have killed a worker.
    3. Nginx is up but Pitchfork is down — nginx would return a 502 Bad Gateway in this case.

    What to check (run these yourself):

    # SSH in
    ssh -i ~/.ssh/navodians.pem ubuntu@52.66.136.102

    # Is the container running?
    sudo docker ps

    # Is unicorn/pitchfork up inside the container?
    sudo docker exec app bash -c "sv status unicorn"

    # Check logs
    sudo docker exec app bash -c "tail -50 /var/log/nginx/error.log"
    sudo docker exec app bash -c "sv restart unicorn"  # if it crashed

    If the container itself is down:
    cd /var/discourse && sudo ./launcher start app

    The sites will come back once Pitchfork finishes booting — it's not a config problem, just a timing/memory issue from the restart.
------------------------------------------------------------------------------------------------------------------------------------------------