from locust import HttpUser, task, between
import random
import re
import uuid

class SockShopUser(HttpUser):
    wait_time = between(1, 3)

    # Tune these weights to control realism:
    W_BROWSE = 6
    W_CART = 3
    W_LOGIN = 1
    W_CHECKOUT = 1  # keep small but non-zero so payment/shipping/orders are exercised

    # ---- Configure these based on your Sock Shop variant (DevTools -> Network) ----
    ENABLE_AUTH = True
    ENABLE_CHECKOUT = True

    # Common-ish endpoints (MAY differ in your deployment)
    LOGIN_PATH = "/login"         # often POST
    REGISTER_PATH = "/register"   # often POST
    CHECKOUT_PATH = "/orders"     # sometimes POST /orders, or /checkout, etc.

    item_ids = []

    def on_start(self):
        # 1) Establish session cookie
        self.client.get("/")

        # 2) Collect product IDs from catalogue (your original logic)
        r = self.client.get("/catalogue")
        self.item_ids = re.findall(
            r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
            r.text,
            re.I
        )
        if not self.item_ids:
            self.item_ids = ["03fef6ac-1896-4ce8-bd69-b798f85c6e0b"]

        # 3) Optional auth at session start (recommended if you want user/user-db workload)
        self.username = f"u_{uuid.uuid4().hex[:10]}"
        self.password = "password"
        self.logged_in = False

        if self.ENABLE_AUTH:
            self._ensure_logged_in()

    # ---------------- Helpers ----------------
    def _ensure_logged_in(self):
        """Try register then login. Mark logged_in=True only if response indicates success."""
        if self.logged_in:
            return True

        # Try register (ignore if 404/405/etc.)
        reg_payload = {"username": self.username, "password": self.password, "email": f"{self.username}@test.com"}
        reg = self.client.post(self.REGISTER_PATH, json=reg_payload, name="auth_register", catch_response=True)
        if reg.status_code in (200, 201, 204, 409):  # 409 = already exists
            reg.success()
        else:
            # don't fail the whole test if your variant doesn't support this endpoint
            reg.failure(f"register not supported or failed: {reg.status_code}")
            reg = None

        # Try login
        login_payload = {"username": self.username, "password": self.password}
        resp = self.client.post(self.LOGIN_PATH, json=login_payload, name="auth_login")
        if resp.status_code in (200, 204):
            self.logged_in = True
            return True

        return False

    # ---------------- Existing tasks (kept) ----------------
    @task(W_BROWSE)
    def home(self):
        self.client.get("/")

    @task(W_BROWSE)
    def browse_catalogue(self):
        self.client.get("/catalogue")
        self.client.get("/category.html")

    @task(2)
    def view_item(self):
        pid = random.choice(self.item_ids)
        self.client.get(f"/detail.html?id={pid}")

    @task(1)
    def view_cart_page(self):
        self.client.get("/basket.html")

    @task(W_CART)
    def add_to_cart(self):
        # Keep your original behavior since it works in your environment.
        pid = random.choice(self.item_ids)
        self.client.get("/cart", json={"id": pid, "quantity": 1})

    # ---------------- New optional tasks ----------------
    @task(W_LOGIN)
    def login_or_register(self):
        if not self.ENABLE_AUTH:
            return
        self._ensure_logged_in()

    @task(W_CHECKOUT)
    def checkout(self):
        """
        This is a placeholder. You MUST confirm the real checkout/order API path + payload
        from browser DevTools (Network tab) in your Sock Shop deployment.
        """
        if not self.ENABLE_CHECKOUT:
            return

        # Make sure we’re logged in if your variant requires it
        if self.ENABLE_AUTH and not self.logged_in:
            if not self._ensure_logged_in():
                return

        # Example payload (very likely differs in your deployment)
        # Use DevTools to capture the real request(s).
        payload = {
            "address": {
                "number": "123",
                "street": "Main St",
                "city": "Bangkok",
                "postcode": "10110",
                "country": "TH"
            },
            "card": {
                "longNum": "4111111111111111",
                "expires": "12/29",
                "ccv": "123"
            }
        }

        self.client.post(self.CHECKOUT_PATH, json=payload, name="checkout_attempt")
