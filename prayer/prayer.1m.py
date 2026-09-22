#!/usr/bin/python3
# SwiftBar plugin: the next prayer + countdown, e.g. "Maghrib 5:31 PM - 1h6m".
# Times come from api.aladhan.com (Doha, Qatar method), fetched a month at a
# time and cached, so it keeps working offline for the rest of the month.
import json, os, urllib.request
from datetime import datetime, timedelta

CITY, COUNTRY, METHOD = "Doha", "Qatar", 10
PRAYERS = ["Fajr", "Dhuhr", "Asr", "Maghrib", "Isha"]
CACHE = os.path.expanduser("~/.cache/prayer-times")

def month(year, mon):
    path = os.path.join(CACHE, f"{year}-{mon:02d}.json")
    if os.path.exists(path):
        with open(path) as f:
            return json.load(f)
    url = (f"https://api.aladhan.com/v1/calendarByCity/{year}/{mon}"
           f"?city={CITY}&country={COUNTRY}&method={METHOD}")
    with urllib.request.urlopen(url, timeout=10) as r:
        days = json.load(r)["data"]
    data = {d["date"]["gregorian"]["date"]: {p: d["timings"][p][:5] for p in PRAYERS}
            for d in days}
    os.makedirs(CACHE, exist_ok=True)
    with open(path + ".tmp", "w") as f:
        json.dump(data, f)
    os.replace(path + ".tmp", path)
    return data

def day_times(day):
    return month(day.year, day.month)[day.strftime("%d-%m-%Y")]

def fmt(dt):
    return dt.strftime("%I:%M %p").lstrip("0")

now = datetime.now()
upcoming = []
try:
    for offset in (0, 1):
        day = now + timedelta(days=offset)
        t = day_times(day)
        for p in PRAYERS:
            h, m = map(int, t[p].split(":"))
            upcoming.append((day.replace(hour=h, minute=m, second=0, microsecond=0), p))
except Exception as e:
    print("Prayer times unavailable")
    print("---")
    print(f"Could not load times (offline?): {e}")
    print("Retry | refresh=true")
    raise SystemExit

today = [x for x in upcoming if x[0].date() == now.date()]
nxt = next(x for x in upcoming if x[0] > now)
secs = int((nxt[0] - now).total_seconds())
h, m = secs // 3600, (secs % 3600) // 60
left = f"{h}h{m}m" if h else f"{m}m"

print(f"{nxt[1]} {fmt(nxt[0])} - {left}")
print("---")
for when, name in today:
    mark = "→ " if (when, name) == nxt else ""
    print(f"{mark}{name}  {fmt(when)} | font=Menlo")
print("---")
print("Refresh | refresh=true")
