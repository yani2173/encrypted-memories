"""Run upgrade cases in order. Every missing observation or failed command is fatal."""


class JourneyError(RuntimeError):
    """The installed app did not complete a required upgrade observation."""


def run_cases(sources, points, execute):
    if not sources or not points:
        raise JourneyError("The upgrade journey requires sources and interruption points")
    for source in sources:
        for point in points:
            execute(source, point)
