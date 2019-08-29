/*
 * Copyright 2017 Google Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

resource "google_compute_global_forwarding_rule" "http" {
  project    = var.project
  count      = var.http_forward ? 1 : 0
  name       = var.name
  target     = google_compute_target_http_proxy.default[0].self_link
  ip_address = google_compute_global_address.default.address
  port_range = "80"
  depends_on = [google_compute_global_address.default]
}

resource "google_compute_global_forwarding_rule" "https" {
  project    = var.project
  count      = var.ssl ? 1 : 0
  name       = "${var.name}-https"
  target     = google_compute_target_https_proxy.default[0].self_link
  ip_address = google_compute_global_address.default.address
  port_range = "443"
  depends_on = [google_compute_global_address.default]
}

resource "google_compute_global_address" "default" {
  project    = var.project
  name       = "${var.name}-address"
  ip_version = var.ip_version
}

# HTTP proxy when ssl is false
resource "google_compute_target_http_proxy" "default" {
  project = var.project
  count   = var.http_forward ? 1 : 0
  name    = "${var.name}-http-proxy"
  url_map = element(
    compact(
      concat([var.url_map], google_compute_url_map.default.*.self_link),
    ),
    0,
  )
}

# HTTPS proxy  when ssl is true
resource "google_compute_target_https_proxy" "default" {
  project = var.project
  count   = var.ssl ? 1 : 0
  name    = "${var.name}-https-proxy"
  url_map = element(
    compact(
      concat([var.url_map], google_compute_url_map.default.*.self_link),
    ),
    0,
  )
  ssl_certificates = compact(
    concat(
      var.ssl_certificates,
      google_compute_ssl_certificate.default.*.self_link,
    ),
  )
}

resource "google_compute_ssl_certificate" "default" {
  project     = var.project
  count       = var.ssl && false == var.use_ssl_certificates ? 1 : 0
  name_prefix = "${var.name}-certificate-"
  private_key = var.private_key
  certificate = var.certificate

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_compute_url_map" "default" {
  project         = var.project
  count           = var.create_url_map ? 1 : 0
  name            = "${var.name}-url-map"
  default_service = google_compute_backend_service.default[0].self_link
}

resource "google_compute_backend_service" "default" {
  for_each        = var.backend_services

  project         = var.project
  name            = "${var.name}-backend-${each.key}"
  port_name       = lookup(each.value, "service_name", "http")
  protocol        = var.backend_protocol
  timeout_sec     = lookup(each.value, "timeout", "86400")
  health_checks   = [google_compute_http_health_check.default[each.key].self_link]
  security_policy = lookup(each.value, "security_policy", var.security_policy)
  enable_cdn      = var.cdn

  dynamic "backend" {
    for_each = each.value.backends
    content {
      balancing_mode               = lookup(backend.value, "balancing_mode", null)
      capacity_scaler              = lookup(backend.value, "capacity_scaler", null)
      description                  = lookup(backend.value, "description", null)
      group                        = lookup(backend.value, "group", null)
      max_connections              = lookup(backend.value, "max_connections", null)
      max_connections_per_instance = lookup(backend.value, "max_connections_per_instance", null)
      max_rate                     = lookup(backend.value, "max_rate", null)
      max_rate_per_instance        = lookup(backend.value, "max_rate_per_instance", null)
      max_utilization              = lookup(backend.value, "max_utilization", null)
    }
  }
}

resource "google_compute_http_health_check" "default" {
  for_each            = var.backend_services

  project             = var.project
  name                = "${var.name}-backend-${each.key}"
  request_path        = lookup(each.value, "healthcheck_path", "/")
  port                = lookup(each.value, "service_port", 80)
  timeout_sec         = lookup(each.value, "timeout_sec", 5)
  check_interval_sec  = lookup(each.value, "check_interval_sec", 5)
}

# Create firewall rule for each backend in each network specified, uses mod behavior of element().
resource "google_compute_firewall" "default-hc" {
  count         = length(var.firewall_networks)
  project       = var.firewall_projects[count.index] == "default" ? var.project : var.firewall_projects[count.index]
  name          = "${var.name}-hc-${count.index}"
  network       = var.firewall_networks[count.index]
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16", "209.85.152.0/22", "209.85.204.0/22"]
  target_tags   = var.target_tags

  allow {
    protocol = "tcp"
    ports    = [for x in var.backend_services: x.service_port]
  }
}
