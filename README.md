# docker-gc-cron

The `docker-gc-cron` container will periodically run the very excellent [Spotify docker-gc script](https://github.com/spotify/docker-gc) script to automatically clean up unused containers and images.  It's particularly useful when deployed on systems onto which large numbers of Docker images and containers are built or pulled, such as CI nodes.

By default, the process will run each night at midnight, but the timing and other behaviors can be precisely specified using standard `cron` syntax. A `docker-compose.yml` file for this purpose can be found in the `compose` directory of this repository to simplify execution.


## Installation tl;dr

```
$ wget https://raw.githubusercontent.com/clockworksoul/docker-gc-cron/master/compose/docker-gc-exclude
$ wget https://raw.githubusercontent.com/clockworksoul/docker-gc-cron/master/compose/docker-compose.yml
$ docker-compose up -d
```

This will pull and execute a `docker-gc-cron` image associated with your installed Docker daemon. By default, the garbage collection process will execute nightly at midnight, but this can be easily changed by modifying the `CRON` property (see below).

Yes, the `docker-gc-exclude` _is_ necessary when using this `docker-compose.yml` file.


## Supported Environmental Settings

The container understands all of the settings that are supported by [docker-gc](https://github.com/spotify/docker-gc), as well as additional settings that can be used to modify the cleanup frequency.

Much of the following documentation is borrowed and modified directly from the [docker-gc README](https://github.com/spotify/docker-gc/blob/master/README.md#excluding-images-from-garbage-collection).


All of the following environmental variables can also be used by getting and modifying the `docker-compose.yml` file.


### Modifying the cleanup schedule

By default, the docker-gc-cron process will run nightly at midnight (cron "0 0 * * *"). This schedule can be overridden by using the `CRON` setting as follows:

```
docker run -d -v /var/run/docker.sock:/var/run/docker.sock -e CRON="0 */6 * * *" clockworksoul/docker-gc-cron:20240219
```

### Running garbage collection on container startup

By default, garbage collection only runs on the scheduled cron time. If you want it to run immediately when the container starts (in addition to the scheduled runs), set `RUN_ON_STARTUP=1`:

```
docker run -d -v /var/run/docker.sock:/var/run/docker.sock -e RUN_ON_STARTUP=1 clockworksoul/docker-gc-cron:20240219
```

This is useful for:
- Cleaning up immediately after container restarts
- Ensuring cleanup happens right away when deploying the container for the first time
- Testing your configuration without waiting for the next scheduled run


### Forcing deletion of images that have multiple tags

By default, docker will not remove an image if it is tagged in multiple repositories. 
If you have a server running Docker where this is the case, for example in CI environments where dockers are being built, re-tagged, and pushed, you can enable a force flag to override this default.

```
docker run -d -v /var/run/docker.sock:/var/run/docker.sock -e FORCE_IMAGE_REMOVAL=1 clockworksoul/docker-gc-cron:20240219
```


### Preserving a minimum number of images for every repository

You might want to always keep a set of the most recent images for any repository. For example, if you are continually rebuilding an image during development you would want to clear out all but the most recent version of an image. To do so, set the `MINIMUM_IMAGES_TO_SAVE=1` environment variable. You can preserve any count of the most recent images, e.g. save the most recent 10 with `MINIMUM_IMAGES_TO_SAVE=10`.

```
docker run -d -v /var/run/docker.sock:/var/run/docker.sock -e MINIMUM_IMAGES_TO_SAVE=3 clockworksoul/docker-gc-cron:20240219
```


### Forcing deletion of containers

By default, if an error is encountered when cleaning up a container, Docker will report the error back and leave it on disk. 
This can sometimes lead to containers accumulating. If you run into this issue, you can force the removal of the container by setting the environment variable below:

```
docker run -d -v /var/run/docker.sock:/var/run/docker.sock -e FORCE_CONTAINER_REMOVAL=1 clockworksoul/docker-gc-cron:20240219
```


### Excluding Recently Exited Containers and Images From Garbage Collection

By default, `docker-gc` will not remove a container if it exited less than 3600 seconds (1 hour) ago. In some cases you might need to change this setting (e.g. you need exited containers to stick around for debugging for several days). Set the `GRACE_PERIOD_SECONDS` variable to override this default.

```
docker run -d -v /var/run/docker.sock:/var/run/docker.sock -e GRACE_PERIOD_SECONDS=86400 clockworksoul/docker-gc-cron:20240219
```

This setting also prevents the removal of images that have been created less than `GRACE_PERIOD_SECONDS` seconds ago.


### Cleaning up orphaned container volumes

Orphaned volumes that were created by containers that no longer exist can, over time, grow to take up a significant amount of disk space. By default, this process will leave any orphaned volumes untouched. However, to instruct the process to automatically clean up any dangling volumes using a `docker volume rm $(docker volume ls -qf dangling=true)` call after the `docker-gc` process has been executed, simply set the `CLEAN_UP_VOLUMES` value to `1`.

```
docker run -d -v /var/run/docker.sock:/var/run/docker.sock -e CLEAN_UP_VOLUMES=1 clockworksoul/docker-gc-cron:20240219
```


### Dry run
By default, `docker-gc` will proceed with deletion of containers and images. To test your command-line options set the `DRY_RUN` variable to override this default.

```
docker run -d -v /var/run/docker.sock:/var/run/docker.sock -e DRY_RUN=1 clockworksoul/docker-gc-cron:20240219
```

### Debugging Why Images Aren't Being Deleted

If you have images that aren't being cleaned up, use the built-in debug script to identify the issue:

```bash
# Run general debug check
docker exec docker-gc sh /debug-gc.sh

# Check a specific image by name or ID
docker exec docker-gc sh /debug-gc.sh myimage:tag
docker exec docker-gc sh /debug-gc.sh sha256:abc123...
```

The debug script checks:
1. **Environment variables** - Verifies GRACE_PERIOD_SECONDS, FORCE_IMAGE_REMOVAL, etc.
2. **Exclude file** - Checks if the image is in `/etc/docker-gc-exclude`
3. **Container usage** - Determines if any containers (running or stopped) reference the image
4. **Image age** - Compares image age against GRACE_PERIOD_SECONDS
5. **Multiple tags** - Checks if image has multiple tags and if FORCE_IMAGE_REMOVAL is set
6. **MINIMUM_IMAGES_TO_SAVE** - Verifies if repository preservation is preventing deletion

**Common reasons images aren't deleted:**
- Image is listed in the exclude file (`/etc/docker-gc-exclude`)
- Image is newer than `GRACE_PERIOD_SECONDS` (default: 1 hour)
- Image is referenced by a stopped container (Docker won't delete images in use)
- Image has multiple tags and `FORCE_IMAGE_REMOVAL=0`
- `MINIMUM_IMAGES_TO_SAVE` is preserving images in the repository

**Manual debugging steps:**
```bash
# 1. Check container logs
docker logs docker-gc

# 2. Run dry-run manually to see what would be deleted
docker exec docker-gc sh -c 'DRY_RUN=1 /usr/bin/docker-gc'

# 3. Check if image is in exclude file
docker exec docker-gc cat /etc/docker-gc-exclude

# 4. Check if image is used by containers
docker ps -a --filter ancestor=IMAGE_NAME

# 5. Check image age
docker inspect --format '{{.Created}}' IMAGE_ID
```


### Webhook Notifications

The container can send webhook notifications for garbage collection events. This allows you to monitor the cleanup process and receive alerts when images or containers are deleted.

#### Configuration

To enable webhook notifications, set the `WEBHOOK_URL` environment variable to your webhook endpoint:

```
docker run -d -v /var/run/docker.sock:/var/run/docker.sock \
  -e WEBHOOK_URL="https://your-webhook-endpoint.com/notify" \
  clockworksoul/docker-gc-cron:20240219
```

You can also configure the webhook timeout (in seconds, default is 10):

```
docker run -d -v /var/run/docker.sock:/var/run/docker.sock \
  -e WEBHOOK_URL="https://your-webhook-endpoint.com/notify" \
  -e WEBHOOK_TIMEOUT=15 \
  clockworksoul/docker-gc-cron:20240219
```

#### Webhook Events

The following events trigger webhook notifications:

1. **`gc_started`** - Sent when the garbage collection process begins
2. **`gc_finished`** - Sent when garbage collection completes successfully (includes summary of all deletions)
3. **`gc_failed`** - Sent if garbage collection encounters an error

**Note:** Individual `image_deleted` and `container_deleted` webhooks are suppressed. All deletion information is included in the `gc_finished` webhook summary.

#### JSON Payload Structure

All webhook payloads follow a consistent JSON structure:

```json
{
  "event_id": "unique-event-identifier",
  "event_type": "gc_started | gc_finished | gc_failed | image_deleted | container_deleted",
  "timestamp": "ISO 8601 timestamp (UTC)",
  "details": {
    "image": {
      "name": "image_name",
      "tag": "image_tag",
      "id": "image_id"
    },
    "container": {
      "name": "container_name",
      "id": "container_id"
    },
    "message": "Human-readable message about the event",
    "error": true
  }
}
```

#### Example Payloads

**Garbage Collection Started:**
```json
{
  "event_id": "1702664680123",
  "event_type": "gc_started",
  "timestamp": "2023-12-15T18:24:40Z",
  "details": {
    "message": "Docker garbage collection process has started"
  }
}
```


**Garbage Collection Finished:**
```json
{
  "event_id": "1702664900123",
  "event_type": "gc_finished",
  "timestamp": "2023-12-15T18:32:00Z",
  "title": "5 images and 3 containers deleted",
  "details": {
    "message": "Docker garbage collection completed successfully. Deleted 5 image(s) and 3 container(s)",
    "summary": {
      "image_count": 5,
      "container_count": 3,
      "images": [
        {
          "name": "myapp",
          "tag": "v1.2.3",
          "id": "sha256:abc123def456"
        },
        {
          "name": "nginx",
          "tag": "latest",
          "id": "sha256:def456ghi789"
        }
      ],
      "containers": [
        {
          "name": "myapp-container",
          "id": "a1b2c3d4e5f6"
        },
        {
          "name": "old-container",
          "id": "b2c3d4e5f6a1"
        }
      ]
    }
  }
}
```

**Garbage Collection Finished (No Actions):**
```json
{
  "event_id": "1702664900123",
  "event_type": "gc_finished",
  "timestamp": "2023-12-15T18:32:00Z",
  "title": "No actions taken",
  "details": {
    "message": "Docker garbage collection completed successfully. No images or containers were deleted",
    "summary": {
      "image_count": 0,
      "container_count": 0,
      "images": [],
      "containers": []
    }
  }
}
```

**Garbage Collection Failed:**
```json
{
  "event_id": "1702664950123",
  "event_type": "gc_failed",
  "timestamp": "2023-12-15T18:33:00Z",
  "details": {
    "message": "Docker garbage collection failed with exit code 1",
    "error": true
  }
}
```

#### Summary Details

The `gc_finished` webhook includes a comprehensive summary:

- **`title`**: Human-readable summary (e.g., "5 images and 3 containers deleted" or "No actions taken")
- **`details.summary.image_count`**: Total number of images deleted
- **`details.summary.container_count`**: Total number of containers deleted
- **`details.summary.images`**: Array of deleted images (limited to first 50 to avoid huge payloads)
  - Each image object contains: `name`, `tag`, and `id`
- **`details.summary.containers`**: Array of deleted containers (limited to first 50 to avoid huge payloads)
  - Each container object contains: `name` and `id`

The arrays are limited to the first 50 items each to prevent webhook payloads from becoming too large. The counts reflect the total number of deletions, even if the arrays are truncated.

#### Notes

- Webhook notifications are sent via HTTP POST requests with `Content-Type: application/json`
- If the webhook URL is not set, the container will operate normally without sending notifications
- Webhook failures are logged but do not interrupt the garbage collection process
- The webhook timeout prevents the garbage collection process from hanging if the webhook endpoint is slow or unavailable
- Individual deletion webhooks are suppressed; all deletion information is included in the `gc_finished` summary
