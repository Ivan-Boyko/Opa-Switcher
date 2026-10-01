import os

/// Сбои перехвата — без набранного текста.
/// Смотреть: log stream --predicate 'subsystem == "com.opa.switcher"'
let log = Logger(subsystem: "com.opa.switcher", category: "tap")
