from locust import HttpUser, task, between
import random
import re

class SockShopUser(HttpUser):
    wait_time = between(1, 3)  # 1–3s think time
    item_ids = []

    def on_start(self):
        # Prime a session and try to collect item IDs from /catalogue for /detail and add-to-cart
        self.client.get("/")  # establish session cookie
        r = self.client.get("/catalogue")
        # Very simple ID scrape (catalogue JSON or HTML with IDs)
        # Matches UUID-like ids seen in Sock Shop (e.g., 03fef6ac-1896-4ce8-bd69-b798f85c6e0b)
        self.item_ids = re.findall(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", r.text, re.I)
        if not self.item_ids:
            # fallback to a known valid demo id
            self.item_ids = ["03fef6ac-1896-4ce8-bd69-b798f85c6e0b"]

    @task(3)
    def home(self):
        self.client.get("/")

    @task(3)
    def browse_catalogue(self):
        self.client.get("/catalogue")
        self.client.get("/category.html")

    @task(1)
    def view_item(self):
        pid = random.choice(self.item_ids)
        self.client.get(f"/detail.html?id={pid}")

    @task(1)
    def view_cart_page(self):
        # UI page for the basket (safe GET)
        self.client.get("/basket.html")

    @task(1)
    def add_to_cart(self):
        # API call via front-end → carts service.
        # Sock Shop accepts {"id": "<productId>", "quantity": 1}
        pid = random.choice(self.item_ids)
        self.client.get("/cart", json={"id": pid, "quantity": 1})