# frozen_string_literal: true

require_relative "test_helper"

# What a delivery tells the push service about *when* to deliver it.
#
# This is the difference between a notification that reaches a locked phone and
# one that waits until the reader happens to open the app, so the header is
# worth a test of its own — no browser, no network, just the words sent.
class TestWebPush < Minitest::Test
  Push = Rubot::Web::Push

  def test_default_urgency_asks_the_service_to_wake_the_device
    headers = Push.delivery_headers(ttl: 60, urgency: Push::DEFAULT_URGENCY)

    assert_equal "high", headers["Urgency"],
                 "`normal` lets a service hold the message until the device wakes"
  end

  def test_urgency_is_normalized_before_it_is_sent
    assert_equal "very-low", Push.normalize_urgency(" Very-Low ")
    assert_equal "low", Push.normalize_urgency(:low)
    assert_equal "normal", Push.normalize_urgency("normal")
  end

  def test_an_urgency_the_rfc_does_not_name_falls_back_to_the_default
    assert_equal Push::DEFAULT_URGENCY, Push.normalize_urgency("urgent")
    assert_equal Push::DEFAULT_URGENCY, Push.normalize_urgency(nil)
    assert_equal Push::DEFAULT_URGENCY, Push.normalize_urgency("")
  end

  def test_ttl_travels_as_a_non_negative_second_count
    assert_equal "90", Push.delivery_headers(ttl: 90, urgency: "high")["TTL"]
    assert_equal "0", Push.delivery_headers(ttl: -5, urgency: "high")["TTL"]
  end

  def test_the_notifier_carries_its_urgency_into_every_delivery
    store = FakeStore.new
    vapor = FakeVapid.new
    seen = []
    Push.stub(:deliver_with_status, lambda { |**kwargs|
      seen << kwargs[:urgency]
      [ :ok, 201 ]
    }) do
      Rubot::Web::Notifier.new(store: store, vapid: vapor, urgency: "low")
                           .deliver(nil, title: "t", body: "b", url: "/", force: true)
    end

    assert_equal [ "low" ], seen
  end

  def test_a_notifier_without_a_choice_uses_the_default_urgency
    store = FakeStore.new
    vapor = FakeVapid.new
    seen = []
    Push.stub(:deliver_with_status, lambda { |**kwargs|
      seen << kwargs[:urgency]
      [ :ok, 201 ]
    }) do
      Rubot::Web::Notifier.new(store: store, vapid: vapor)
                           .deliver(nil, title: "t", body: "b", url: "/", force: true)
    end

    assert_equal [ Push::DEFAULT_URGENCY ], seen
  end

  class FakeStore
    def push_subscriptions(_slug)
      [ { "endpoint" => "https://push.example/abc" } ]
    end

    def drop_push_subscription(_endpoint)
      flunk "a :ok delivery must not drop the subscription"
    end
  end

  class FakeVapid
    def key
      :fake_key
    end
  end
end
