//
//  BoringCalendar.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 08/09/24.
//

import Defaults
import SwiftUI

struct Config: Equatable {
    //    var count: Int = 10  // 3 days past + today + 7 days future
    var past: Int = 7
    var future: Int = 14
    var steps: Int = 1  // Each step is one day
    var spacing: CGFloat = 0
    var showsText: Bool = true
}

struct WheelPicker: View {
    @EnvironmentObject var vm: BoringViewModel
    @Binding var selectedDate: Date
    @State private var scrollPosition: Int?
    @State private var haptics: Bool = false
    @State private var byClick: Bool = false
    let config: Config

    /// How many days are on screen at once, and it has to be odd.
    ///
    /// The old wheel let every cell size itself, so a column was as wide as its own day
    /// name — "Wed" is wider than "Fri" — and an even number of them fitted the strip.
    /// Centring the selected cell in that layout put two days on one side and three on
    /// the other, which is exactly what it looked like. Equal-width cells and an odd
    /// count are what make "centred" and "same number either side" the same statement.
    private static func visibleCount(for width: CGFloat) -> Int {
        // A three-letter day name at .caption needs about 30 pt to breathe.
        let fits = Int(width / 30)
        let odd = fits.isMultiple(of: 2) ? fits - 1 : fits
        return max(3, min(odd, 9))
    }

    var body: some View {
        GeometryReader { geometry in
            let visible = Self.visibleCount(for: geometry.size.width)
            let cellWidth = geometry.size.width / CGFloat(visible)
            // Half a screen of blanks at each end, so the first and last real dates can
            // still be scrolled to the middle rather than stopping short of it.
            let spacerNum = (visible - 1) / 2

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: config.spacing) {
                    let dateCount = totalDateItems()
                    let totalItems = dateCount + 2 * spacerNum
                    ForEach(0..<totalItems, id: \.self) { index in
                        if index < spacerNum || index >= spacerNum + dateCount {
                            Color.clear
                                .frame(width: cellWidth, height: 24)
                                .id(index)
                        } else {
                            let date = dateForItemIndex(index: index, spacerNum: spacerNum)
                            let isSelected = Calendar.current.isDate(date, inSameDayAs: selectedDate)
                            dateButton(date: date, isSelected: isSelected, id: index) {
                                selectedDate = date
                                byClick = true
                                withAnimation {
                                    scrollPosition = index
                                }
                                if Defaults[.enableHaptics] {
                                    haptics.toggle()
                                }
                            }
                            .frame(width: cellWidth)
                        }
                    }
                }
                .frame(height: 50)
                .scrollTargetLayout()
            }
            .scrollIndicators(.never)
            .scrollPosition(id: $scrollPosition, anchor: .center)
            .scrollTargetBehavior(.viewAligned)  // Ensures scroll view snaps the centered view
            .sensoryFeedback(.alignment, trigger: haptics)
            .onChange(of: scrollPosition) { oldValue, newValue in
                if !byClick {
                    handleScrollChange(newValue: newValue, spacerNum: spacerNum)
                } else {
                    byClick = false
                }
            }
            .onAppear {
                byClick = true
                scrollPosition = indexForDate(Date(), spacerNum: spacerNum)
                selectedDate = Date()
            }
            // When parent updates the bound selectedDate (e.g., view reopen), center the wheel on it
            .onChange(of: selectedDate) { _, newValue in
                let targetIndex = indexForDate(newValue, spacerNum: spacerNum)
                if scrollPosition != targetIndex {
                    byClick = true
                    withAnimation {
                        scrollPosition = targetIndex
                    }
                }
            }
        }
        .frame(height: 50)
    }

    private func dateButton(
        date: Date, isSelected: Bool, id: Int, onClick: @escaping () -> Void
    ) -> some View {
        let isToday = Calendar.current.isDateInToday(date)
        return Button(action: onClick) {
            VStack(spacing: 8) {
                dayText(date: dateToString(for: date), isToday: isToday, isSelected: isSelected)
                dateCircle(date: date, isToday: isToday, isSelected: isSelected)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(isSelected ? Color.effectiveAccentBackground : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(PlainButtonStyle())
        .id(id)
    }

    private func dayText(date: String, isToday: Bool, isSelected: Bool) -> some View {
        Text(date)
            .font(.caption)
            .foregroundColor(isSelected ? .white : Color(white: 0.65))
    }

    private func dateCircle(date: Date, isToday: Bool, isSelected: Bool) -> some View {
        ZStack {
            Circle()
                .fill(isToday ? Color.effectiveAccent : .clear)
                .frame(width: 20, height: 20)
                .overlay(
                    Circle()
                        .stroke(Color.gray.opacity(0.3), lineWidth: 0)
                )
            Text("\(date.date)")
                .font(.body)
                .fontWeight(.medium)
                .foregroundColor(isSelected ? .white : Color(white: isToday ? 0.9 : 0.65))
        }
    }

    func handleScrollChange(newValue: Int?, spacerNum: Int) {
        guard let newIndex = newValue else { return }
        let dateCount = totalDateItems()
        guard (spacerNum..<(spacerNum + dateCount)).contains(newIndex) else { return }
        let date = dateForItemIndex(index: newIndex, spacerNum: spacerNum)
        if !Calendar.current.isDate(date, inSameDayAs: selectedDate) {
            selectedDate = date
            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
        }
    }

    // MARK: - Index/Date mapping with steps and spacers
    private func indexForDate(_ date: Date, spacerNum: Int) -> Int {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let startDate = cal.startOfDay(for: cal.date(byAdding: .day, value: -config.past, to: today) ?? today)
        let target = cal.startOfDay(for: date)
        let days = cal.dateComponents([.day], from: startDate, to: target).day ?? 0
        let stepIndex = max(0, min(days / max(config.steps, 1), totalDateItems() - 1))
        return spacerNum + stepIndex
    }

    private func dateForItemIndex(index: Int, spacerNum: Int) -> Date {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let startDate = cal.date(byAdding: .day, value: -config.past, to: today) ?? today
        let stepIndex = index - spacerNum
        return cal.date(byAdding: .day, value: stepIndex * max(config.steps, 1), to: startDate) ?? today
    }

    private func totalDateItems() -> Int {
        let range = config.past + config.future
        let step = max(config.steps, 1)
        return Int(ceil(Double(range) / Double(step))) + 1
    }

    private func dateToString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "E"
        return formatter.string(from: date)
    }
}

struct CalendarView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var calendarManager = CalendarManager.shared
    @ObservedObject private var weather = WeatherManager.shared
    @State private var selectedDate = Date()
    @Default(.calendarShowsTemperature) private var showsTemperature

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                // Month over temperature. The year was the one thing on this panel
                // nobody has ever needed to look up — the dates below it already say
                // which month we are in, and 2026 does not change. What is outside does.
                // Click it to put the year back.
                VStack(alignment: .leading) {
                    Text(selectedDate.formatted(.dateTime.month(.abbreviated)))
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                    Text(secondLine)
                        .font(.title3)
                        .fontWeight(.light)
                        .foregroundColor(Color(white: 0.65))
                        .contentTransition(.numericText())
                }
                .fixedSize(horizontal: true, vertical: false)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.smooth(duration: 0.25)) { showsTemperature.toggle() }
                }
                .help(showsTemperature ? weather.statusMessage : "Show the temperature")

                WheelPicker(selectedDate: $selectedDate, config: Config())
                    // Masked rather than overlaid with black. The old version painted two
                    // opaque black gradients on top of the wheel, which was invisible only
                    // because the notch behind it was also black — over any other backdrop
                    // they read as two dark bars flanking the dates. A mask fades the
                    // content itself, so whatever is behind shows through.
                    // A sliver, not a wash. The cells now divide the strip exactly, so
                    // the outermost days are whole days rather than the half-cells the
                    // old 9% fade was there to hide — fading that far in just dimmed two
                    // legible dates.
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black, location: 0.035),
                                .init(color: .black, location: 0.965),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing))
            }

            let filteredEvents = EventListView.filteredEvents(
                events: calendarManager.events
            )
            if filteredEvents.isEmpty {
                EmptyEventsView(selectedDate: selectedDate)
                Spacer(minLength: 0)
            } else {
                EventListView(events: calendarManager.events)
            }
        }
        .listRowBackground(Color.clear)
        .frame(height: 120)
        .onChange(of: selectedDate) {
            Task {
                await calendarManager.updateCurrentDate(selectedDate)
            }
        }
        .onChange(of: vm.notchState) { _, _ in
            Task {
                await calendarManager.updateCurrentDate(Date.now)
                selectedDate = Date.now
            }
        }
        .onAppear {
            // Cached for 15 minutes inside the manager, so an open notch costs at most
            // four lookups an hour and usually none.
            weather.refresh()
            Task {
                await calendarManager.updateCurrentDate(Date.now)
                selectedDate = Date.now
            }
        }
    }

    /// Temperature when there is one to show, the year when there is not — a place that
    /// has never been set should not leave a dash sitting under the month.
    private var secondLine: String {
        if showsTemperature, let temperature = weather.temperatureText {
            return temperature
        }
        return selectedDate.formatted(.dateTime.year())
    }
}

struct EmptyEventsView: View {
    let selectedDate: Date
    
    var body: some View {
        VStack {
            Image(systemName: "calendar.badge.checkmark")
                .font(.title)
                .foregroundColor(Color(white: 0.65))
            Text(Calendar.current.isDateInToday(selectedDate) ? "No events today" : "No events")
                .font(.subheadline)
                .foregroundColor(.white)
            Text("Enjoy your free time!")
                .font(.caption)
                .foregroundColor(Color(white: 0.65))
        }
    }
}

struct EventListView: View {
    @Environment(\.openURL) private var openURL
    @ObservedObject private var calendarManager = CalendarManager.shared
    let events: [EventModel]
    @Default(.autoScrollToNextEvent) private var autoScrollToNextEvent
    @Default(.showFullEventTitles) private var showFullEventTitles


    static func filteredEvents(events: [EventModel]) -> [EventModel] {
        events.filter { event in
            if event.type.isReminder {
                if case .reminder(let completed) = event.type {
                    return !completed || !Defaults[.hideCompletedReminders]
                }
            }
            // Filter out all-day events if setting is enabled
            if event.isAllDay && Defaults[.hideAllDayEvents] {
                return false
            }
            return true
        }
    }

    private var filteredEvents: [EventModel] {
        Self.filteredEvents(events: events)
    }

    private func scrollToRelevantEvent(proxy: ScrollViewProxy) {
        let now = Date()
        // Determine a single target using preferred search order:
        // 1) first non-all-day upcoming/in-progress event
        // 2) first all-day event
        // 3) last event (fallback)
        let nonAllDayUpcoming = filteredEvents.first(where: { !$0.isAllDay && $0.end > now })
        let firstAllDay = filteredEvents.first(where: { $0.isAllDay })
        let lastEvent = filteredEvents.last
        guard let target = nonAllDayUpcoming ?? firstAllDay ?? lastEvent else { return }

        Task { @MainActor in
            withTransaction(Transaction(animation: nil)) {
                proxy.scrollTo(target.id, anchor: .top)
            }
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(filteredEvents) { event in
                    Button(action: {
                        if let url = event.calendarAppURL() {
                            openURL(url)
                        }
                    }) {
                        eventRow(event)
                    }
                    .id(event.id)
                    .padding(.leading, -5)
                    .buttonStyle(PlainButtonStyle())
                    .listRowSeparator(.automatic)
                    .listRowSeparatorTint(.gray.opacity(0.2))
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollIndicators(.never)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .onAppear {
                scrollToRelevantEvent(proxy: proxy)
            }
            .onChange(of: filteredEvents) { _, _ in
                scrollToRelevantEvent(proxy: proxy)
            }
        }
        Spacer(minLength: 0)
    }

    private func eventRow(_ event: EventModel) -> some View {
        if event.type.isReminder {
            let isCompleted: Bool
            if case .reminder(let completed) = event.type {
                isCompleted = completed
            } else {
                isCompleted = false
            }
            return AnyView(
                HStack(spacing: 8) {
                    ReminderToggle(
                        isOn: Binding(
                            get: { isCompleted },
                            set: { newValue in
                                Task {
                                    await calendarManager.setReminderCompleted(
                                        reminderID: event.id, completed: newValue
                                    )
                                }
                            }
                        ),
                        color: Color(event.calendar.color)
                    )
                    .opacity(1.0)  // Ensure the toggle is always fully opaque
                    HStack {
                        Text(event.title)
                            .font(.callout)
                            .foregroundColor(.white)
                            .lineLimit(showFullEventTitles ? nil : 1)
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 4) {
                            if event.isAllDay {
                                Text("All-day")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                            } else {
                                Text(event.start, style: .time)
                                    .foregroundColor(.white)
                                    .font(.caption)
                            }
                        }
                    }
                    .opacity(
                        isCompleted
                            ? 0.4
                            : event.start < Date.now && Calendar.current.isDateInToday(event.start)
                                ? 0.6 : 1.0
                    )
                }
                .padding(.vertical, 4)
            )
        } else {
            return AnyView(
                HStack(alignment: .top, spacing: 4) {
                    Rectangle()
                        .fill(Color(event.calendar.color))
                        .frame(width: 3)
                        .cornerRadius(1.5)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title)
                            .font(.callout)
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                            .lineLimit(showFullEventTitles ? nil : 2)

                        if let location = event.location, !location.isEmpty {
                            Text(location)
                                .font(.caption)
                                .foregroundColor(Color(white: 0.65))
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 4) {
                        if event.isAllDay {
                            Text("All-day")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.white)
                                .lineLimit(1)
                        } else {
                            Text(event.start, style: .time)
                                .foregroundColor(.white)
                            Text(event.end, style: .time)
                                .foregroundColor(Color(white: 0.65))
                        }
                    }
                    .font(.caption)
                    .frame(minWidth: 44, alignment: .trailing)
                }
                .opacity(
                    event.eventStatus == .ended && Calendar.current.isDateInToday(event.start)
                        ? 0.6 : 1.0)
            )
        }
    }
}

struct ReminderToggle: View {
    @Binding var isOn: Bool
    var color: Color

    var body: some View {
        Button(action: {
            isOn.toggle()
        }) {
            ZStack {
                // Outer ring
                Circle()
                    .strokeBorder(color, lineWidth: 2)
                    .frame(width: 14, height: 14)
                // Inner fill
                if isOn {
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)
                }
                Circle()
                    .fill(Color.black.opacity(0.001))
                    .frame(width: 14, height: 14)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .padding(0)
        .accessibilityLabel(isOn ? "Mark as incomplete" : "Mark as complete")
    }
}

#Preview {
    CalendarView()
        .frame(width: 215, height: 130)
        .background(.black)
        .environmentObject(BoringViewModel())
}
