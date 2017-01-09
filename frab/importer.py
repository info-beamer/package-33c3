import re
import sys
import traceback
import requests
import calendar
import pytz
from operator import itemgetter
from datetime import timedelta

import dateutil.parser
import defusedxml.ElementTree as ET

def cleanhtml(raw_html):
    cleanr = re.compile('<.*?>')
    cleantext = re.sub(cleanr, '', raw_html)
    return cleantext

def get_schedule(url, group):
    def load_events(xml):
        def to_unixtimestamp(dt):
            dt = dt.astimezone(pytz.utc)
            ts = int(calendar.timegm(dt.timetuple()))
            return ts
        def text_or_empty(node, child_name):
            child = node.find(child_name)
            if child is None:
                return u""
            if child.text is None:
                return u""
            return unicode(child.text)
        def parse_duration(value):
            h, m = map(int, value.split(':'))
            return timedelta(hours=h, minutes=m)

        def all_events():
            schedule = ET.fromstring(xml)
            for day in schedule.findall('day'):
                for room in day.findall('room'):
                    for event in room.findall('event'):
                        yield event

        parsed_events = []
        for event in all_events():
            start = dateutil.parser.parse(event.find('date').text)
            duration = parse_duration(event.find('duration').text)
            end = start + duration

            persons = event.find('persons')
            if persons is not None:
                persons = persons.findall('person')

            links = event.find('links')
            if links is not None:
                links = links.findall('link')

            parsed_events.append(dict(
                start = start.astimezone(pytz.utc),
                start_str = start.strftime('%H:%M'),
                end_str = end.strftime('%H:%M'),
                start_unix  = to_unixtimestamp(start),
                end_unix = to_unixtimestamp(end),
                duration = int(duration.total_seconds() / 60),
                title = text_or_empty(event, 'title'),
                place = text_or_empty(event, 'room'),
                abstract = cleanhtml(text_or_empty(event, 'abstract')),
                speakers = [
                    unicode(person.text.strip()) 
                    for person in persons
                ] if persons else [],
                link = unicode(links[0].attrib.get('href', '')) if links else '',
                lang = text_or_empty(event, 'language') or "unk",
                id = event.attrib["id"],
                group = group,
            ))
        return parsed_events

    r = requests.get(url, timeout=30, stream=True, headers={
        'Accept-Encoding': 'identity'
    })
    schedule = r.raw.read()

    # resp = urllib2.urlopen(url)
    # schedule = resp.read()
    return load_events(schedule)
